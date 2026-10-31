// phrase-stream: phrase-by-phrase live transcription with Qwen3-ASR.
//
// Audio is fed at real-time pace in small slices. Silero VAD (streamed, one
// probability per 32 ms frame) cuts it into phrases at short pauses; each
// phrase is transcribed on its own by a worker thread while the next one is
// still being spoken, with the text so far passed as context prompt. The
// model stays loaded across phrases and utterances. Language is detected per
// phrase (no fixed language) and recorded.
//
//   phrase-stream -m ASR.gguf --vad VAD.gguf [options] WAV...
//
// One JSON line per WAV on stdout (phrases with timings, the joined text, an
// optional whole-utterance offline run of the same audio, CPU time, RSS).
// All times are milliseconds from the start of the utterance's audio.

#include "transcribe.h"
#include "transcribe/vad.h"

#include <sys/resource.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using clk = std::chrono::steady_clock;
constexpr int kRate = 16000;

struct Options {
    std::string asr_path, vad_path;
    int         threads       = 8;
    int         vad_threads   = 1;
    double      threshold     = 0.5;
    double      neg_threshold = -1;    // < 0: max(threshold - 0.15, 0.01)
    int         min_pause_ms  = 300;   // silence that ends a phrase
    int         min_phrase_ms = 1000;  // shorter phrases wait for the next pause
    int         max_phrase_ms = 6000;  // longer phrases are split at the quietest frame
    int         long_pause_ms = 800;   // a short phrase is emitted anyway after this much silence
    int         min_speech_ms = 250;   // phrases with less speech than this are dropped
    int         pad_ms        = 200;   // audio kept before and after each phrase
    int         slice_ms      = 20;    // feeder slice
    int         context_chars = -1;    // text so far given as context: -1 all, 0 none, N last N bytes
    bool        realtime      = true;
    bool        offline       = true;  // also transcribe the whole utterance at the end
    bool        offline_only  = false;
    bool        vad_only      = false;  // segment only, no transcription (for tuning)
    int         spec_k        = -1;
    std::vector<std::string> wavs;
};

double ms_since(clk::time_point t0) {
    return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}

double cpu_ms() {
    rusage ru{};
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e3 + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e3;
}

long peak_rss_kib() {
    rusage ru{};
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss;
}

// Minimal RIFF reader: 16 kHz mono PCM16 or float32.
bool read_wav(const std::string & path, std::vector<float> & out) {
    FILE * f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::vector<uint8_t> b;
    uint8_t              buf[65536];
    size_t               n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) b.insert(b.end(), buf, buf + n);
    std::fclose(f);
    if (b.size() < 12 || std::memcmp(b.data(), "RIFF", 4) || std::memcmp(b.data() + 8, "WAVE", 4)) return false;
    int    fmt = 0, ch = 0, rate = 0, bits = 0;
    size_t p   = 12;
    while (p + 8 <= b.size()) {
        uint32_t sz;
        std::memcpy(&sz, b.data() + p + 4, 4);
        const uint8_t * d = b.data() + p + 8;
        if (!std::memcmp(b.data() + p, "fmt ", 4)) {
            fmt  = d[0] | d[1] << 8;
            ch   = d[2] | d[3] << 8;
            std::memcpy(&rate, d + 4, 4);
            bits = d[14] | d[15] << 8;
        } else if (!std::memcmp(b.data() + p, "data", 4)) {
            if (ch != 1 || rate != kRate) return false;
            sz = std::min<size_t>(sz, b.size() - p - 8);
            if (fmt == 1 && bits == 16) {
                out.resize(sz / 2);
                for (size_t i = 0; i < out.size(); ++i) {
                    int16_t s;
                    std::memcpy(&s, d + 2 * i, 2);
                    out[i] = s / 32768.0f;
                }
            } else if (fmt == 3 && bits == 32) {
                out.resize(sz / 4);
                std::memcpy(out.data(), d, out.size() * 4);
            } else {
                return false;
            }
            return true;
        }
        p += 8 + sz + (sz & 1);
    }
    return false;
}

void json_str(std::string & o, const std::string & s) {
    o += '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += (char) c; }
        else if (c == '\n') o += "\\n";
        else if (c < 0x20) { char e[8]; std::snprintf(e, sizeof e, "\\u%04x", c); o += e; }
        else o += (char) c;
    }
    o += '"';
}

std::string fmt(const char * f, double v) {
    char b[64];
    std::snprintf(b, sizeof b, f, v);
    return b;
}

// Join phrase texts: a space between two Latin-script ends, nothing otherwise
// (Japanese and Mandarin are written without spaces).
void join_text(std::string & acc, const std::string & add) {
    if (add.empty()) return;
    if (!acc.empty()) {
        const unsigned char a = acc.back(), b = add.front();
        if (a < 0x80 && b < 0x80 && a != ' ' && b != ' ') acc += ' ';
    }
    acc += add;
}

// Keep the last n bytes of s, starting on a UTF-8 character boundary.
std::string tail_utf8(const std::string & s, size_t n) {
    if (s.size() <= n) return s;
    size_t p = s.size() - n;
    while (p < s.size() && (static_cast<unsigned char>(s[p]) & 0xC0) == 0x80) ++p;
    return s.substr(p);
}

std::string trim(const char * t) {
    std::string s = t ? t : "";
    size_t a = s.find_first_not_of(" \t\n"), e = s.find_last_not_of(" \t\n");
    return a == std::string::npos ? "" : s.substr(a, e - a + 1);
}

struct Phrase {
    int64_t     start = 0, end = 0;  // samples, padded
    int64_t     speech_end = 0;      // samples, where VAD saw speech stop (or the forced cut)
    bool        forced     = false;  // split at max_phrase_ms rather than at a pause
    double      t_cut      = 0;      // wall ms when the cut was decided
    double      t_start = 0, t_done = 0;
    double      mel = 0, enc = 0, dec = 0;
    int         ctx_bytes = 0;
    int         status    = 0;
    std::string text, lang;
};

// Silero-style segmentation over streamed frame probabilities.
class Segmenter {
public:
    Segmenter(const Options & o, int frame) : o_(o), frame_(frame) {
        neg_ = o.neg_threshold >= 0 ? o.neg_threshold : std::max(o.threshold - 0.15, 0.01);
    }

    // Feed the probability of frame i (covering samples [i*frame, (i+1)*frame)).
    // Appends finished phrases to out.
    void frame(int64_t i, float p, std::vector<Phrase> & out) {
        probs_.push_back(p);
        const int64_t now = (i + 1) * frame_;
        if (!in_) {
            if (p >= o_.threshold) {
                in_         = true;
                seg_start_  = std::max(i * frame_ - ms(o_.pad_ms), last_end_);
                speech_on_  = i * frame_;
                sil_start_  = -1;
                speech_smp_ = 0;
            }
            return;
        }
        if (p >= o_.threshold) {
            sil_start_ = -1;
        } else if (p < neg_ && sil_start_ < 0) {
            sil_start_ = i;
        }
        if (sil_start_ < 0 || p >= neg_) speech_smp_ += frame_;
        if (sil_start_ >= 0) {
            const int64_t sil   = now - sil_start_ * frame_;
            const int64_t s_end = sil_start_ * frame_;
            const bool    long_enough = s_end - speech_on_ >= ms(o_.min_phrase_ms);
            if ((sil >= ms(o_.min_pause_ms) && long_enough) || sil >= ms(o_.long_pause_ms)) {
                emit(s_end, std::min(s_end + ms(o_.pad_ms), now), false, out);
                return;
            }
        }
        if (now - seg_start_ >= ms(o_.max_phrase_ms)) {
            // Split at the quietest frame in the second half of the phrase.
            const int64_t f0 = (seg_start_ + ms(o_.max_phrase_ms) / 2) / frame_, f1 = i;
            int64_t       best = f1;
            for (int64_t f = f0; f <= f1; ++f)
                if (probs_[f] < probs_[best]) best = f;
            const int64_t cut = best * frame_ + frame_ / 2;
            emit(cut, cut, true, out);
            in_         = true;  // speech continues in the next phrase
            seg_start_  = cut;
            speech_on_  = cut;
            sil_start_  = -1;
            // The audio between the cut and now was inside speech: count it, so
            // the remainder is not dropped as a blip if a pause follows at once.
            speech_smp_ = now - cut;
        }
    }

    // End of input: close an open phrase.
    void flush(int64_t n_samples, std::vector<Phrase> & out) {
        if (in_) {
            const int64_t s_end = sil_start_ >= 0 ? sil_start_ * frame_ : n_samples;
            emit(s_end, std::min(s_end + ms(o_.pad_ms), n_samples), false, out);
        }
    }

private:
    int64_t ms(int v) const { return (int64_t) v * kRate / 1000; }

    void emit(int64_t speech_end, int64_t end, bool forced, std::vector<Phrase> & out) {
        in_ = false;
        if (speech_smp_ < ms(o_.min_speech_ms) && !forced) return;  // noise blip
        Phrase ph;
        ph.start      = seg_start_;
        ph.end        = end;
        ph.speech_end = speech_end;
        ph.forced     = forced;
        out.push_back(ph);
        last_end_ = end;
    }

    const Options &    o_;
    int                frame_;
    double             neg_;
    std::vector<float> probs_;
    bool               in_ = false;
    int64_t            seg_start_ = 0, speech_on_ = 0, sil_start_ = -1, speech_smp_ = 0, last_end_ = 0;
};

struct Engine {
    const Options &                o;
    transcribe_session *           asr = nullptr;
    transcribe_vad_session *       vad = nullptr;
    int                            frame = 512;

    // Transcribe pcm with optional context; returns status.
    int run(const float * pcm, int n, const std::string & ctx, Phrase & ph) {
        transcribe_run_params rp;
        transcribe_run_params_init(&rp);
        rp.language      = nullptr;  // detect per phrase
        rp.timestamps    = TRANSCRIBE_TIMESTAMPS_NONE;
        rp.prompt        = ctx.empty() ? nullptr : ctx.c_str();
        rp.spec_k_drafts = o.spec_k;
        const int st     = transcribe_run(asr, pcm, n, &rp);
        transcribe_timings tm;
        transcribe_timings_init(&tm);
        transcribe_get_timings(asr, &tm);
        ph.mel  = tm.mel_ms;
        ph.enc  = tm.encode_ms;
        ph.dec  = tm.decode_ms;
        ph.text = trim(transcribe_full_text(asr));
        ph.lang = transcribe_detected_language(asr) ? transcribe_detected_language(asr) : "";
        ph.status    = st;
        ph.ctx_bytes = (int) ctx.size();
        return st;
    }
};

std::string phrase_json(const Phrase & p) {
    std::string o = "{";
    o += "\"start\":" + fmt("%.0f", p.start * 1e3 / kRate);
    o += ",\"end\":" + fmt("%.0f", p.end * 1e3 / kRate);
    o += ",\"speech_end\":" + fmt("%.0f", p.speech_end * 1e3 / kRate);
    o += std::string(",\"forced\":") + (p.forced ? "true" : "false");
    o += ",\"t_cut\":" + fmt("%.1f", p.t_cut);
    o += ",\"t_start\":" + fmt("%.1f", p.t_start);
    o += ",\"t_done\":" + fmt("%.1f", p.t_done);
    o += ",\"mel\":" + fmt("%.1f", p.mel) + ",\"enc\":" + fmt("%.1f", p.enc) + ",\"dec\":" + fmt("%.1f", p.dec);
    o += ",\"ctx_bytes\":" + std::to_string(p.ctx_bytes) + ",\"status\":" + std::to_string(p.status);
    o += ",\"lang\":";
    json_str(o, p.lang);
    o += ",\"text\":";
    json_str(o, p.text);
    return o + "}";
}

void process(Engine & e, const std::string & path) {
    const Options &    o = e.o;
    std::vector<float> pcm;
    if (!read_wav(path, pcm)) {
        std::fprintf(stderr, "cannot read %s (16 kHz mono PCM16/float32 WAV)\n", path.c_str());
        return;
    }
    const int64_t n   = (int64_t) pcm.size();
    std::string   out = "{\"wav\":";
    json_str(out, path);
    out += ",\"audio_ms\":" + fmt("%.0f", n * 1e3 / kRate);

    // Reference speech end: offline VAD over the whole clip, unpadded.
    {
        transcribe_vad_params vp;
        transcribe_vad_params_init(&vp);
        vp.threshold     = o.threshold;
        vp.speech_pad_ms = 0;
        transcribe_vad_run(e.vad, pcm.data(), (int) n, &vp);
        transcribe_vad_result r;
        transcribe_vad_result_init(&r);
        transcribe_vad_get_result(e.vad, &r);
        int64_t s0 = 0, s1 = n;
        if (r.n_segments > 0) {
            transcribe_vad_segment s;
            transcribe_vad_segment_init(&s);
            transcribe_vad_get_segment(e.vad, 0, &s);
            s0 = s.start_sample;
            transcribe_vad_get_segment(e.vad, r.n_segments - 1, &s);
            s1 = s.end_sample;
        }
        out += ",\"speech_start\":" + fmt("%.0f", s0 * 1e3 / kRate);
        out += ",\"speech_end\":" + fmt("%.0f", s1 * 1e3 / kRate);
        out += ",\"vad_segments\":" + std::to_string(r.n_segments);
    }

    std::vector<Phrase> done;
    double              t_feed_end = 0, cpu_feed = 0, cpu_feed_end = 0, cpu_final = 0, late_max = 0;
    std::string         joined;
    if (!o.offline_only) {
        std::mutex              mu;
        std::condition_variable cv;
        std::deque<Phrase>      queue;
        bool                    finished = false;
        std::atomic<double>     busy_ms{ 0 };
        clk::time_point         t0;

        std::thread worker([&] {
            std::string text_so_far;
            for (;;) {
                Phrase ph;
                {
                    std::unique_lock<std::mutex> lk(mu);
                    cv.wait(lk, [&] { return !queue.empty() || finished; });
                    if (queue.empty()) return;
                    ph = queue.front();
                    queue.pop_front();
                }
                std::string ctx;
                if (o.context_chars < 0) ctx = text_so_far;
                else if (o.context_chars > 0) ctx = tail_utf8(text_so_far, (size_t) o.context_chars);
                ph.t_start = ms_since(t0);
                if (!o.vad_only) e.run(pcm.data() + ph.start, (int) (ph.end - ph.start), ctx, ph);
                ph.t_done = ms_since(t0);
                busy_ms   = busy_ms + (ph.t_done - ph.t_start);
                join_text(text_so_far, ph.text);
                // Emitted the moment it is ready (stderr, for watching live).
                std::fprintf(stderr, "[%7.0f ms] %s: %s\n", ph.t_done, ph.lang.c_str(), ph.text.c_str());
                std::lock_guard<std::mutex> lk(mu);
                done.push_back(ph);
            }
        });

        transcribe_vad_stream_reset(e.vad);
        Segmenter             seg(o, e.frame);
        std::vector<Phrase>   cut;
        transcribe_vad_result r;
        transcribe_vad_result_init(&r);
        const int64_t slice = (int64_t) o.slice_ms * kRate / 1000;
        t0                  = clk::now();
        const double c0     = cpu_ms();
        auto         submit = [&](double t) {
            if (cut.empty()) return;
            std::lock_guard<std::mutex> lk(mu);
            for (auto & ph : cut) {
                ph.t_cut = t;
                queue.push_back(ph);
            }
            cut.clear();
            cv.notify_one();
        };
        for (int64_t pos = 0; pos < n; pos += slice) {
            const int64_t m = std::min(slice, n - pos);
            if (o.realtime) {
                // Slice [pos, pos+m) is available once its last sample has been "spoken".
                const auto due = t0 + std::chrono::microseconds((pos + m) * 1000000 / kRate);
                std::this_thread::sleep_until(due);
                late_max = std::max(late_max, std::chrono::duration<double, std::milli>(clk::now() - due).count());
            }
            transcribe_vad_stream_feed(e.vad, pcm.data() + pos, (int) m);
            transcribe_vad_get_result(e.vad, &r);
            const float * p = transcribe_vad_probs(e.vad);
            for (int k = 0; k < r.n_probs; ++k) seg.frame(r.first_frame + k, p[k], cut);
            submit(ms_since(t0));
        }
        seg.flush(n, cut);
        t_feed_end   = ms_since(t0);
        cpu_feed_end = cpu_ms();
        cpu_feed     = cpu_feed_end - c0;
        submit(t_feed_end);
        {
            std::lock_guard<std::mutex> lk(mu);
            finished = true;
        }
        cv.notify_one();
        worker.join();
        cpu_final = cpu_ms() - c0;
        for (auto & ph : done) join_text(joined, ph.text);
        out += ",\"feed_end\":" + fmt("%.1f", t_feed_end) + ",\"feed_late_max\":" + fmt("%.1f", late_max);
        out += ",\"cpu_feed_ms\":" + fmt("%.0f", cpu_feed) + ",\"cpu_total_ms\":" + fmt("%.0f", cpu_final);
        out += ",\"asr_busy_ms\":" + fmt("%.0f", busy_ms.load());
        out += ",\"phrases\":[";
        for (size_t i = 0; i < done.size(); ++i) out += (i ? "," : "") + phrase_json(done[i]);
        out += "],\"text\":";
        json_str(out, joined);
    }
    if ((o.offline || o.offline_only) && !o.vad_only) {
        Phrase     whole;
        const auto t1 = clk::now();
        e.run(pcm.data(), (int) n, "", whole);
        const double wall = ms_since(t1);
        out += ",\"offline\":{\"wall\":" + fmt("%.1f", wall) + ",\"mel\":" + fmt("%.1f", whole.mel) +
               ",\"enc\":" + fmt("%.1f", whole.enc) + ",\"dec\":" + fmt("%.1f", whole.dec) +
               ",\"status\":" + std::to_string(whole.status) + ",\"lang\":";
        json_str(out, whole.lang);
        out += ",\"text\":";
        json_str(out, whole.text);
        out += "}";
    }
    out += ",\"peak_rss_kib\":" + std::to_string(peak_rss_kib()) + "}";
    std::printf("%s\n", out.c_str());
    std::fflush(stdout);
}

void log_cb(transcribe_log_level level, const char * msg, void *) {
    if (level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR) std::fprintf(stderr, "%s", msg);
}

void usage() {
    std::fprintf(stderr,
                 "usage: phrase-stream -m ASR.gguf --vad VAD.gguf [options] WAV...\n"
                 "  -t N                ASR threads (8)\n"
                 "  --threshold P       VAD speech probability (0.5)\n"
                 "  --min-pause MS      silence that ends a phrase (300)\n"
                 "  --min-phrase MS     shorter phrases wait for the next pause (1000)\n"
                 "  --max-phrase MS     longer phrases are split (6000)\n"
                 "  --long-pause MS     a short phrase is emitted anyway after this silence (800)\n"
                 "  --pad MS            audio kept around each phrase (200)\n"
                 "  --context N         context prompt: -1 all text so far, 0 none, N last N bytes (-1)\n"
                 "  --no-realtime       feed as fast as possible\n"
                 "  --no-offline        skip the whole-utterance comparison run\n"
                 "  --offline-only      only the whole-utterance run\n"
                 "  --vad-only          segment only, no transcription\n"
                 "  --spec-k N          speculative draft length (-1 model default, 0 off)\n");
}

}  // namespace

int main(int argc, char ** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string a    = argv[i];
        auto        next = [&]() -> const char * {
            if (i + 1 >= argc) { usage(); std::exit(2); }
            return argv[++i];
        };
        if (a == "-m") o.asr_path = next();
        else if (a == "--vad") o.vad_path = next();
        else if (a == "-t") o.threads = std::atoi(next());
        else if (a == "--threshold") o.threshold = std::atof(next());
        else if (a == "--min-pause") o.min_pause_ms = std::atoi(next());
        else if (a == "--min-phrase") o.min_phrase_ms = std::atoi(next());
        else if (a == "--max-phrase") o.max_phrase_ms = std::atoi(next());
        else if (a == "--long-pause") o.long_pause_ms = std::atoi(next());
        else if (a == "--pad") o.pad_ms = std::atoi(next());
        else if (a == "--context") o.context_chars = std::atoi(next());
        else if (a == "--spec-k") o.spec_k = std::atoi(next());
        else if (a == "--no-realtime") o.realtime = false;
        else if (a == "--no-offline") o.offline = false;
        else if (a == "--offline-only") o.offline_only = true;
        else if (a == "--vad-only") o.vad_only = true;
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else if (!a.empty() && a[0] == '-') { usage(); return 2; }
        else o.wavs.push_back(a);
    }
    if (o.asr_path.empty() || o.vad_path.empty() || o.wavs.empty()) { usage(); return 2; }
    transcribe_log_set(log_cb, nullptr);

    transcribe_model * asr_model = nullptr, *vad_model = nullptr;
    int                st = transcribe_model_load_file(o.asr_path.c_str(), nullptr, &asr_model);
    if (st != TRANSCRIBE_OK) { std::fprintf(stderr, "load %s: %s\n", o.asr_path.c_str(), transcribe_status_string(st)); return 1; }
    st = transcribe_model_load_file(o.vad_path.c_str(), nullptr, &vad_model);
    if (st != TRANSCRIBE_OK) { std::fprintf(stderr, "load %s: %s\n", o.vad_path.c_str(), transcribe_status_string(st)); return 1; }
    if (!transcribe_model_supports(asr_model, TRANSCRIBE_FEATURE_CONTEXT_PROMPT))
        std::fprintf(stderr, "warning: model has no context prompt support\n");

    Engine e{ o };
    transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_threads = o.threads;
    if ((st = transcribe_session_init(asr_model, &sp, &e.asr)) != TRANSCRIBE_OK) { std::fprintf(stderr, "asr session: %s\n", transcribe_status_string(st)); return 1; }
    transcribe_vad_session_params vsp;
    transcribe_vad_session_params_init(&vsp);
    vsp.n_threads = o.vad_threads;
    if ((st = transcribe_vad_session_init(vad_model, &vsp, &e.vad)) != TRANSCRIBE_OK) { std::fprintf(stderr, "vad session: %s\n", transcribe_status_string(st)); return 1; }
    transcribe_vad_info vi;
    transcribe_vad_info_init(&vi);
    transcribe_vad_get_info(vad_model, &vi);
    e.frame = vi.frame_samples;

    // Warm-up: first runs pay for graph and scheduler allocation.
    {
        std::vector<float> warm(kRate * 2);
        uint32_t           x = 1;
        for (auto & v : warm) { x = x * 1664525u + 1013904223u; v = ((x >> 8) / 16777216.0f - 0.5f) * 0.01f; }
        Phrase ph;
        e.run(warm.data(), (int) warm.size(), "warm", ph);
        transcribe_vad_stream_feed(e.vad, warm.data(), (int) warm.size());
        transcribe_vad_stream_reset(e.vad);
    }
    std::fprintf(stderr, "loaded; peak RSS %ld KiB\n", peak_rss_kib());
    for (const auto & w : o.wavs) process(e, w);

    transcribe_vad_session_free(e.vad);
    transcribe_session_free(e.asr);
    transcribe_model_free(vad_model);
    transcribe_model_free(asr_model);
    return 0;
}
