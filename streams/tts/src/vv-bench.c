// Timing of VOICEVOX CORE (C API) on a list of Japanese lines: per line,
// each sentence (cut at 。！？) is analysed (Open JTalk, durations, pitch:
// voicevox_synthesizer_create_audio_query) and then rendered
// (voicevox_synthesizer_synthesis), in order. Reports the time to the
// first sentence's audio, the total, the audio length and the peak RSS.
//
//   vv-bench ORT_LIB DICT_DIR VVM STYLE_ID THREADS LINES.tsv [OUTDIR]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "voicevox_core.h"

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}

static long status_kib(const char *key) {
  FILE *f = fopen("/proc/self/status", "r");
  char l[256];
  long v = 0;
  while (f && fgets(l, sizeof l, f))
    if (!strncmp(l, key, strlen(key))) v = atol(l + strlen(key));
  if (f) fclose(f);
  return v;
}

#define TRY(x)                                                              \
  do {                                                                      \
    VoicevoxResultCode r_ = (x);                                            \
    if (r_ != VOICEVOX_RESULT_OK) {                                         \
      fprintf(stderr, "vv-bench: %s: %s\n", #x, voicevox_error_result_to_message(r_)); \
      exit(1);                                                              \
    }                                                                       \
  } while (0)

int main(int argc, char **argv) {
  if (argc < 7) {
    fprintf(stderr, "usage: vv-bench ORT_LIB DICT_DIR VVM STYLE_ID THREADS LINES.tsv [OUTDIR]\n");
    return 2;
  }
  const char *outdir = argc > 7 ? argv[7] : NULL;
  VoicevoxStyleId style = (VoicevoxStyleId)atoi(argv[4]);
  long rss0 = status_kib("VmRSS:");
  double t0 = now();
  struct VoicevoxLoadOnnxruntimeOptions lo = voicevox_make_default_load_onnxruntime_options();
  lo.filename = argv[1];
  const struct VoicevoxOnnxruntime *ort;
  TRY(voicevox_onnxruntime_load_once(lo, &ort));
  struct OpenJtalkRc *oj;
  TRY(voicevox_open_jtalk_rc_new(argv[2], &oj));
  struct VoicevoxInitializeOptions io = voicevox_make_default_initialize_options();
  io.acceleration_mode = VOICEVOX_ACCELERATION_MODE_CPU;
  io.cpu_num_threads = (uint16_t)atoi(argv[5]);
  struct VoicevoxSynthesizer *syn;
  TRY(voicevox_synthesizer_new(ort, oj, io, &syn));
  struct VoicevoxVoiceModelFile *vm;
  TRY(voicevox_voice_model_file_open(argv[3], &vm));
  TRY(voicevox_synthesizer_load_voice_model(syn, vm, voicevox_make_default_load_voice_model_options()));
  fprintf(stderr, "vv-bench: loaded in %.2f s, rss %ld -> %ld KiB\n", now() - t0, rss0, status_kib("VmRSS:"));
  // Warm-up.
  {
    char *q;
    uintptr_t n;
    uint8_t *w;
    TRY(voicevox_synthesizer_create_audio_query(syn, "こんにちは。", style, &q));
    TRY(voicevox_synthesizer_synthesis(syn, q, style, voicevox_make_default_synthesis_options(), &n, &w));
    voicevox_string_free(q);
    voicevox_bytes_free(w);
  }
  FILE *f = fopen(argv[6], "r");
  char *ln = NULL;
  size_t cap = 0;
  while (f && getline(&ln, &cap, f) > 0) {
    ln[strcspn(ln, "\r\n")] = 0;
    char *id = ln, *tab = strchr(ln, '\t');
    if (!tab) continue;
    *tab = 0;
    char *lang = tab + 1, *text = strchr(lang, '\t');
    if (!text) continue;
    *text++ = 0;
    double s0 = now(), first = 0, query_s = 0, synth_s = 0, audio_s = 0;
    // Sentences: up to and including each 。！？
    char *p = text;
    FILE *wav = NULL;
    long pcm_bytes = 0;
    if (outdir) {
      char path[1024];
      snprintf(path, sizeof path, "%s/%s.raw", outdir, id);
      wav = fopen(path, "wb");
    }
    while (*p) {
      char *e = NULL;
      const char *marks[] = {"。", "！", "？"};
      for (int k = 0; k < 3; k++) {
        char *m = strstr(p, marks[k]);
        if (m && (!e || m < e)) e = m;
      }
      size_t len = e ? (size_t)(e - p) + 3 : strlen(p);
      char *sent = strndup(p, len);
      p += len;
      double a = now();
      char *q;
      uintptr_t n;
      uint8_t *w;
      TRY(voicevox_synthesizer_create_audio_query(syn, sent, style, &q));
      double b = now();
      TRY(voicevox_synthesizer_synthesis(syn, q, style, voicevox_make_default_synthesis_options(), &n, &w));
      double c = now();
      query_s += b - a;
      synth_s += c - b;
      if (!first) first = c - s0;
      // WAV: 44-byte header, 16-bit mono at 24 kHz.
      audio_s += (double)(n - 44) / 2 / 24000;
      if (wav) {
        fwrite(w + 44, 1, n - 44, wav);
        pcm_bytes += n - 44;
      }
      voicevox_string_free(q);
      voicevox_bytes_free(w);
      free(sent);
    }
    if (wav) fclose(wav);
    double tot = now() - s0;
    printf("{\"id\":\"%s\",\"audio_s\":%.3f,\"synth_s\":%.3f,\"rtf\":%.3f,\"first_s\":%.3f,\"query_s\":%.3f,\"decode_s\":%.3f,\"rss_kib\":%ld,\"hwm_kib\":%ld}\n",
           id, audio_s, tot, tot / audio_s, first, query_s, synth_s, status_kib("VmRSS:"), status_kib("VmHWM:"));
    fflush(stdout);
  }
  return 0;
}
