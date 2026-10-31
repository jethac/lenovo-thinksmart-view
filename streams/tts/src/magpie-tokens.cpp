// Print MagpieTTS text tokens from the native front end and time it.
//
//   magpie-tokens TOKENIZER_DIR LANG TEXT_FILE [REPEATS]
//
// TEXT_FILE holds one utterance per line. Prints, per line, the token IDs of each
// sentence chunk (space separated, chunks separated by " | "), then on stderr the
// time to construct the tokenizer, the first call per language (loads the
// language's dictionaries) and the median of REPEATS further calls.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "tts/tokenizer/tokenizer.h"

using clk = std::chrono::steady_clock;
static double ms_since(clk::time_point t) {
    return std::chrono::duration<double, std::milli>(clk::now() - t).count();
}

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: %s TOKENIZER_DIR LANG TEXT_FILE [REPEATS]\n", argv[0]);
        return 2;
    }
    const std::string lang = argv[2];
    const int repeats = argc > 4 ? std::atoi(argv[4]) : 5;
    std::vector<std::string> lines;
    std::ifstream in(argv[3]);
    for (std::string l; std::getline(in, l);)
        if (!l.empty()) lines.push_back(l);

    auto t0 = clk::now();
    nemo_speech::tts::MagpieNativeTokenizer tok(argv[1]);
    const double init_ms = ms_since(t0);
    bool first = true;
    double first_ms = 0;
    for (const auto& line : lines) {
        auto t1 = clk::now();
        auto r = tok.tokenize(line, lang);
        const double once = ms_since(t1);
        if (first) { first_ms = once; first = false; }
        std::vector<double> times;
        for (int i = 0; i < repeats; ++i) {
            auto t2 = clk::now();
            (void)tok.tokenize(line, lang);
            times.push_back(ms_since(t2));
        }
        std::sort(times.begin(), times.end());
        std::string out;
        for (size_t c = 0; c < r.chunks.size(); ++c) {
            if (c) out += " |";
            for (int32_t t : r.chunks[c].tokens) out += " " + std::to_string(t);
        }
        std::printf("%s\n", out.c_str() + (out.empty() ? 0 : 1));
        std::fprintf(stderr, "tokens=%zu chunks=%zu call_ms=%.2f median_ms=%.2f tokenizer=%s\n",
                     r.tokens.size(), r.chunks.size(), once,
                     times.empty() ? once : times[times.size() / 2], r.tokenizer_name.c_str());
    }
    std::fprintf(stderr, "init_ms=%.1f first_call_ms=%.1f\n", init_ms, first_ms);
    return 0;
}
