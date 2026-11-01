// sla-bench: straylight-listen's recogniser (straylight-voice listen/asr,
// libstraylight_asr.a) over WAV files, with either backend:
//
//   sla-bench --vad VAD.gguf --qwen ASR.gguf [options] WAV...
//   sla-bench --vad VAD.gguf --sherpa-lib LIB.so [--offline KIND:DIR] [--online KIND:DIR]
//             [--online-langs en] [--partial-ms 700] [--online-threads 2] [--spin]
//             [--hotwords FILE] [options] WAV...
//
// Options: --threads N (6), --nice N (5), --tail-ms MS (1200: silence after
// each file), --max-phrase-ms MS, --gain DB (as --asr-gain), --no-realtime.
//
// Each file is one utterance, fed in 20 ms slices at real-time pace (as the
// capture thread would), then the tail of silence, sla_finish, and the events
// until the utterance is complete. One JSON line per file on stdout: the
// phrases (the recogniser's times, ms from sla_begin, language, text), the
// live-text events (time, the audio span they cover and when its end was fed,
// text), the joined text, CPU time during the audio and after it, the
// feeder's lateness against the real-time schedule, and the RSS (file-backed
// and anonymous).
#include "straylight_asr.h"

#include <sys/resource.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using clk = std::chrono::steady_clock;

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

long status_kb(const char * key) {
    std::ifstream f("/proc/self/status");
    std::string   l;
    while (std::getline(f, l))
        if (l.compare(0, std::strlen(key), key) == 0) return std::atol(l.c_str() + std::strlen(key));
    return 0;
}

}  // namespace

int main(int argc, char ** argv) {
    std::string qwen, vad, lib, offline, online, online_langs = "en", hotwords;
    int         tail_ms = 1200;
    bool        realtime = true;
    sla_config  cfg;
    sla_config_init(&cfg);
    sla_sherpa_config sc;
    sla_sherpa_config_init(&sc);
    std::vector<std::string> wavs;
    for (int i = 1; i < argc; ++i) {
        std::string a    = argv[i];
        auto        next = [&]() { return i + 1 < argc ? argv[++i] : (std::exit(2), argv[0]); };
        if (a == "--qwen") qwen = next();
        else if (a == "--vad") vad = next();
        else if (a == "--sherpa-lib") lib = next();
        else if (a == "--offline") offline = next();
        else if (a == "--online") online = next();
        else if (a == "--online-langs") online_langs = next();
        else if (a == "--hotwords") hotwords = next();
        else if (a == "--hotwords-score") sc.hotwords_score = (float) std::atof(next());
        else if (a == "--partial-ms") sc.partial_ms = std::atoi(next());
        else if (a == "--lid-ms") sc.lid_ms = std::atoi(next());
        else if (a == "--online-threads") sc.online_threads = std::atoi(next());
        else if (a == "--online-step-ms") sc.online_step_ms = std::atoi(next());
        else if (a == "--online-tail-ms") sc.online_tail_ms = std::atoi(next());
        else if (a == "--spin") sc.spin = 1;
        else if (a == "--threads") cfg.threads = std::atoi(next());
        else if (a == "--nice") cfg.worker_nice = std::atoi(next());
        else if (a == "--max-phrase-ms") cfg.max_phrase_ms = std::atoi(next());
        else if (a == "--gain") cfg.gain_db = (float) std::atof(next());
        else if (a == "--tail-ms") tail_ms = std::atoi(next());
        else if (a == "--no-realtime") realtime = false;
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "sla-bench: unknown option %s (see the source header)\n", a.c_str());
            return 2;
        } else wavs.push_back(a);
    }
    if (vad.empty() || wavs.empty() || (qwen.empty() && lib.empty())) {
        std::fprintf(stderr, "sla-bench: need --vad, --qwen or --sherpa-lib, and WAV files\n");
        return 2;
    }
    char         err[512] = "";
    const auto   tl0      = clk::now();
    sla_engine * e        = nullptr;
    if (!qwen.empty()) {
        e = sla_open(qwen.c_str(), vad.c_str(), &cfg, err, sizeof err);
    } else {
        sc.lib          = lib.c_str();
        sc.offline      = offline.empty() ? nullptr : offline.c_str();
        sc.online       = online.empty() ? nullptr : online.c_str();
        sc.online_langs = online_langs.c_str();
        sc.hotwords     = hotwords.empty() ? nullptr : hotwords.c_str();
        e = sla_open_sherpa(&sc, vad.c_str(), &cfg, err, sizeof err);
    }
    if (!e) {
        std::fprintf(stderr, "sla-bench: %s\n", err);
        return 1;
    }
    const double load_ms = std::chrono::duration<double, std::milli>(clk::now() - tl0).count();
    std::fprintf(stderr, "sla-bench: open in %.0f ms, rss %ld kB (file %ld, anon %ld)\n", load_ms,
                 status_kb("VmRSS:"), status_kb("RssFile:"), status_kb("RssAnon:"));

    const int slice = 320;  // 20 ms
    int       n_run = 0;
    for (const auto & wav : wavs) {
        std::vector<float> pcm;
        if (!read_wav(wav.c_str(), pcm)) {
            std::fprintf(stderr, "sla-bench: cannot read %s (16 kHz mono 16-bit)\n", wav.c_str());
            continue;
        }
        const size_t n_audio = pcm.size();
        pcm.resize(pcm.size() + (size_t) tail_ms * 16, 0.0f);
        const double cpu0 = cpu_s();
        double       cpu_audio = 0;
        sla_begin(e);
        const auto  t0 = clk::now();
        std::string ph_json, part_json, joined;
        int         n_ph = 0, n_part = 0;
        double      late_max = 0, late_sum = 0;
        int         late_n = 0, late_over20 = 0;
        auto        drain = [&](bool block) {
            sla_event ev;
            for (;;) {
                const int r = sla_poll(e, &ev);
                if (r == 1) {
                    const std::string text(ev.text ? ev.text : "", ev.text ? ev.text_len : 0);
                    char b[1024];
                    if (ev.kind == SLA_EV_PARTIAL) {
                        std::snprintf(b, sizeof b,
                                      "%s{\"i\":%d,\"start\":%.1f,\"end\":%.1f,\"t_cov\":%.1f,\"t\":%.1f,\"lang\":\"%s\","
                                      "\"text\":",
                                      n_part ? "," : "", ev.index, ev.start / 16.0, ev.end / 16.0, ev.t_speech_end,
                                      ev.t_done, ev.lang);
                        part_json += b + jstr(text) + "}";
                        ++n_part;
                        continue;
                    }
                    if (ev.kind != SLA_EV_PHRASE) continue;
                    if (!text.empty()) {
                        if (!joined.empty() && (unsigned char) joined.back() < 0x80 && (unsigned char) text[0] < 0x80 &&
                            joined.back() != ' ' && text[0] != ' ')
                            joined += ' ';
                        joined += text;
                    }
                    std::snprintf(b, sizeof b,
                                  "%s{\"i\":%d,\"start\":%.1f,\"end\":%.1f,\"speech_end\":%.1f,\"forced\":%d,"
                                  "\"streamed\":%d,\"status\":%d,\"t_speech_end\":%.1f,\"t_cut\":%.1f,"
                                  "\"t_start\":%.1f,\"t_final\":%.1f,\"t_done\":%.1f,\"mel\":%.1f,\"enc\":%.1f,"
                                  "\"dec\":%.1f,\"lang\":\"%s\",\"text\":",
                                  n_ph ? "," : "", ev.index, ev.start / 16.0, ev.end / 16.0, ev.speech_end / 16.0,
                                  ev.forced, ev.streamed, ev.status, ev.t_speech_end, ev.t_cut, ev.t_start, ev.t_final,
                                  ev.t_done, ev.mel_ms, ev.enc_ms, ev.dec_ms, ev.lang);
                    ph_json += b + jstr(text) + "}";
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
                const double late = std::chrono::duration<double, std::milli>(clk::now() - due).count();
                late_max = std::max(late_max, late);
                late_sum += late;
                ++late_n;
                if (late > 20) ++late_over20;
            }
            const auto f0 = clk::now();
            sla_feed(e, pcm.data() + pos, (int) n);
            drain(false);
            (void) f0;
            if (pos + n >= n_audio && cpu_audio == 0) cpu_audio = cpu_s() - cpu0;
        }
        sla_finish(e);
        drain(true);
        const double t_end = sla_now_ms(e);
        sla_status st;
        sla_get_status(e, &st);
        rusage u{};
        getrusage(RUSAGE_SELF, &u);
        char b[512];
        std::snprintf(b, sizeof b,
                      "{\"file\":%s,\"audio_ms\":%zu,\"t_end\":%.1f,\"cpu_audio_s\":%.2f,\"cpu_s\":%.2f,"
                      "\"late_max_ms\":%.1f,\"late_mean_ms\":%.2f,\"late_over20\":%d,\"vad_ms_max\":%.1f,"
                      "\"maxrss_mb\":%.1f,\"rss_file_mb\":%.1f,\"rss_anon_mb\":%.1f,",
                      jstr(wav).c_str(), n_audio / 16, t_end, cpu_audio, cpu_s() - cpu0, late_max,
                      late_n ? late_sum / late_n : 0.0, late_over20, st.vad_ms_max, u.ru_maxrss / 1024.0,
                      status_kb("RssFile:") / 1024.0, status_kb("RssAnon:") / 1024.0);
        std::printf("%s\"phrases\":[%s],\"partials\":[%s],\"text\":%s}\n", b, ph_json.c_str(), part_json.c_str(),
                    jstr(joined).c_str());
        std::fflush(stdout);
        ++n_run;
    }
    sla_close(e);
    return n_run > 0 ? 0 : 1;
}
