// sla-file: straylight-listen's recogniser (straylight-voice listen/asr,
// straylight_asr.cpp) over WAV files, without the rest of the pipeline.
//
//   sla-file -m ASR.gguf --vad VAD.gguf [options] WAV...
//
// Each file is one utterance: sla_begin, the audio in 20 ms slices at
// real-time pace (as the capture thread would feed it), then --tail-ms of
// silence, sla_finish, and the events until the utterance is complete. One
// JSON line per file on stdout: per phrase the recogniser's times (ms from
// sla_begin), stage times, language and text, plus the decoder prefill line
// transcribe.cpp logs with TRANSCRIBE_PERF_DEBUG (prompt tokens, how many came
// from the prompt-prefix cache, header draft, prefill time).
//
// --modes LIST runs every file once per mode in the same process, rotating
// which goes first, so all of them see the same device state. Modes (the
// "cache" field of the output): off (TRANSCRIBE_QWEN3_NO_PREFIX_CACHE=1: the
// 0001+0002 path), prefix (the prompt-prefix cache of patches/0003, the
// default), draft (plus the opt-in header draft), force (an
// experiment: later phrases of an utterance forced to the language the last
// detected one had, TRANSCRIBE_QWEN3_FORCE_LAST_HEADER). Default: prefix only.

#include "straylight_asr.h"

#include "transcribe.h"

#include <sys/resource.h>

#include <chrono>
#include <cmath>
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

std::mutex              log_mu;
std::deque<std::string> prefill_lines;  // "qwen3_asr prefill: ..." in run order
std::vector<std::string> begin_lines;   // "qwen3_asr stream begin: ..."

void log_cb(transcribe_log_level level, const char * msg, void *) {
    if (std::strstr(msg, "qwen3_asr prefill:") != nullptr) {
        std::lock_guard<std::mutex> lk(log_mu);
        prefill_lines.emplace_back(std::strstr(msg, "qwen3_asr prefill:") + 19);
    } else if (std::strstr(msg, "qwen3_asr stream begin:") != nullptr) {
        std::lock_guard<std::mutex> lk(log_mu);
        begin_lines.emplace_back(std::strstr(msg, "qwen3_asr stream begin:") + 24);
    } else if (level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR) {
        std::fprintf(stderr, "sla-file: %s", msg);
    }
}

std::string jstr(const std::string & s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += (char) c; }
        else if (c == '\n') o += "\\n";
        else if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += (char) c;
    }
    return o + "\"";
}

std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
    return s;
}

// 16-bit PCM mono 16 kHz WAV, as int16-scale floats.
bool read_wav(const char * path, std::vector<float> & out) {
    FILE * f = std::fopen(path, "rb");
    if (!f) return false;
    char hdr[12];
    if (std::fread(hdr, 1, 12, f) != 12 || std::memcmp(hdr, "RIFF", 4) || std::memcmp(hdr + 8, "WAVE", 4)) {
        std::fclose(f);
        return false;
    }
    int ch = 0, rate = 0, bits = 0;
    for (;;) {
        char     id[4];
        uint32_t sz;
        if (std::fread(id, 1, 4, f) != 4 || std::fread(&sz, 4, 1, f) != 1) break;
        if (!std::memcmp(id, "fmt ", 4)) {
            std::vector<uint8_t> b(sz);
            if (std::fread(b.data(), 1, sz, f) != sz) break;
            ch   = b[2] | b[3] << 8;
            rate = b[4] | b[5] << 8 | b[6] << 16 | b[7] << 24;
            bits = b[14] | b[15] << 8;
        } else if (!std::memcmp(id, "data", 4)) {
            if (ch != 1 || rate != 16000 || bits != 16) break;
            std::vector<int16_t> s(sz / 2);
            const size_t         n = std::fread(s.data(), 2, s.size(), f);
            out.assign(s.begin(), s.begin() + n);
            std::fclose(f);
            return true;
        } else {
            std::fseek(f, sz + (sz & 1), SEEK_CUR);
        }
    }
    std::fclose(f);
    return false;
}

double cpu_s() {
    rusage u{};
    getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
}

}  // namespace

int main(int argc, char ** argv) {
    std::string asr, vad;
    int         tail_ms = 1200;
    bool        realtime = true;
    std::vector<std::string> modes = { "prefix" };
    sla_config  cfg;
    sla_config_init(&cfg);
    std::vector<std::string> wavs;
    for (int i = 1; i < argc; ++i) {
        std::string a    = argv[i];
        auto        next = [&]() { return i + 1 < argc ? argv[++i] : (std::exit(2), argv[0]); };
        if (a == "-m") asr = next();
        else if (a == "--vad") vad = next();
        else if (a == "--threads") cfg.threads = std::atoi(next());
        else if (a == "--nice") cfg.worker_nice = std::atoi(next());
        else if (a == "--no-stream") cfg.streaming = 0;
        else if (a == "--context") cfg.context_bytes = std::atoi(next());
        else if (a == "--tail-ms") tail_ms = std::atoi(next());
        else if (a == "--modes") {
            modes.clear();
            std::string l = next();
            for (size_t p = 0; p <= l.size();) {
                const size_t q = std::min(l.find(',', p), l.size());
                if (q > p) modes.push_back(l.substr(p, q - p));
                p = q + 1;
            }
        }
        else if (a == "--no-realtime") realtime = false;
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr,
                         "usage: sla-file -m ASR.gguf --vad VAD.gguf [--threads N] [--nice N] [--no-stream]\n"
                         "                [--context N] [--tail-ms MS] [--modes off,prefix,draft,force] [--no-realtime] WAV...\n");
            return 2;
        } else wavs.push_back(a);
    }
    if (asr.empty() || vad.empty() || wavs.empty()) {
        std::fprintf(stderr, "sla-file: need -m, --vad and WAV files\n");
        return 2;
    }
    setenv("TRANSCRIBE_PERF_DEBUG", "1", 1);
    char         err[512] = "";
    sla_engine * e        = sla_open(asr.c_str(), vad.c_str(), &cfg, err, sizeof err);
    if (!e) {
        std::fprintf(stderr, "sla-file: %s\n", err);
        return 1;
    }
    transcribe_log_set(log_cb, nullptr);  // after sla_open, which sets its own
    {
        std::lock_guard<std::mutex> lk(log_mu);
        prefill_lines.clear();
        begin_lines.clear();
    }

    const int slice = 320;  // 20 ms
    int       n_run = 0;
    for (size_t w = 0; w < wavs.size(); ++w) {
        std::vector<float> pcm;
        if (!read_wav(wavs[w].c_str(), pcm)) {
            std::fprintf(stderr, "sla-file: cannot read %s (16 kHz mono 16-bit)\n", wavs[w].c_str());
            continue;
        }
        pcm.resize(pcm.size() + (size_t) tail_ms * 16, 0.0f);
        for (size_t k = 0; k < modes.size(); ++k) {
            const std::string & mode = modes[(w + k) % modes.size()];
            if (mode == "off") setenv("TRANSCRIBE_QWEN3_NO_PREFIX_CACHE", "1", 1);
            else unsetenv("TRANSCRIBE_QWEN3_NO_PREFIX_CACHE");
            if (mode == "draft" || mode == "force") setenv("TRANSCRIBE_QWEN3_HEADER_DRAFT", "1", 1);
            else unsetenv("TRANSCRIBE_QWEN3_HEADER_DRAFT");
            if (mode == "force") setenv("TRANSCRIBE_QWEN3_FORCE_LAST_HEADER", "1", 1);
            else unsetenv("TRANSCRIBE_QWEN3_FORCE_LAST_HEADER");
            {
                std::lock_guard<std::mutex> lk(log_mu);
                prefill_lines.clear();
                begin_lines.clear();
            }
            const double cpu0 = cpu_s();
            sla_begin(e);
            const auto t0 = clk::now();
            std::string out = "{\"file\":" + jstr(wavs[w]) + ",\"cache\":" + jstr(mode) +
                              ",\"audio_ms\":" + std::to_string((pcm.size() - (size_t) tail_ms * 16) / 16) +
                              ",\"phrases\":[";
            std::string joined;
            int         n_ph = 0;
            double      late_max = 0;
            auto        drain = [&](bool block) {
                sla_event ev;
                for (;;) {
                    const int r = sla_poll(e, &ev);
                    if (r == 1) {
                        if (ev.kind != SLA_EV_PHRASE) continue;
                        std::string pl;
                        {
                            std::lock_guard<std::mutex> lk(log_mu);
                            if (!prefill_lines.empty()) {
                                pl = trim(prefill_lines.front());
                                prefill_lines.pop_front();
                            }
                        }
                        const std::string text(ev.text, ev.text_len);
                        if (!text.empty()) {
                            if (!joined.empty() && (unsigned char) joined.back() < 0x80 &&
                                (unsigned char) text[0] < 0x80 && joined.back() != ' ' && text[0] != ' ')
                                joined += ' ';
                            joined += text;
                        }
                        char b[1024];
                        std::snprintf(b, sizeof b,
                                      "%s{\"i\":%d,\"start\":%.1f,\"end\":%.1f,\"speech_end\":%.1f,\"forced\":%d,"
                                      "\"streamed\":%d,\"status\":%d,\"t_speech_end\":%.1f,\"t_cut\":%.1f,"
                                      "\"t_start\":%.1f,\"t_final\":%.1f,\"t_done\":%.1f,\"mel\":%.1f,\"enc\":%.1f,"
                                      "\"dec\":%.1f,\"ctx_bytes\":%d,\"lang\":\"%s\",\"prefill\":",
                                      n_ph ? "," : "", ev.index, ev.start / 16.0, ev.end / 16.0, ev.speech_end / 16.0,
                                      ev.forced, ev.streamed, ev.status, ev.t_speech_end, ev.t_cut, ev.t_start,
                                      ev.t_final, ev.t_done, ev.mel_ms, ev.enc_ms, ev.dec_ms, ev.ctx_bytes, ev.lang);
                        out += b + jstr(pl) + ",\"text\":" + jstr(text) + "}";
                        ++n_ph;
                        continue;
                    }
                    if (r < 0 || !block) return r;
                    std::this_thread::sleep_for(std::chrono::milliseconds(5));
                }
            };
            for (size_t pos = 0; pos < pcm.size(); pos += slice) {
                const size_t n = std::min((size_t) slice, pcm.size() - pos);
                if (realtime) {
                    const auto due = t0 + std::chrono::microseconds((int64_t) ((pos + n) * 1e6 / 16000));
                    std::this_thread::sleep_until(due);
                    late_max = std::max(late_max, std::chrono::duration<double, std::milli>(clk::now() - due).count());
                }
                sla_feed(e, pcm.data() + pos, (int) n);
                drain(false);
            }
            sla_finish(e);
            drain(true);
            const double t_end = sla_now_ms(e);
            std::string  bl;
            {
                std::lock_guard<std::mutex> lk(log_mu);
                for (size_t k = 0; k < begin_lines.size(); ++k) bl += (k ? "," : "") + jstr(trim(begin_lines[k]));
            }
            rusage u{};
            getrusage(RUSAGE_SELF, &u);
            char b[256];
            std::snprintf(b, sizeof b, "],\"t_end\":%.1f,\"cpu_s\":%.2f,\"late_max_ms\":%.1f,\"maxrss_mb\":%.1f",
                          t_end, cpu_s() - cpu0, late_max, u.ru_maxrss / 1024.0);
            out += b;
            out += ",\"begin\":[" + bl + "],\"text\":" + jstr(joined) + "}";
            std::printf("%s\n", out.c_str());
            std::fflush(stdout);
            ++n_run;
        }
    }
    sla_close(e);
    return n_run > 0 ? 0 : 1;
}
