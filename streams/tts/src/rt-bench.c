// Timing of one sherpa-onnx offline TTS model on a list of lines: per line,
// the time to the first sentence's audio, the total synthesis time, the
// audio length and the peak RSS. Phoneme-input models (Piper VITS, Matcha,
// Kitten) take pre-computed phonemes (4th column, sentences separated by
// '|'); the others read the text.
//
//   rt-bench KIND [options] LINES.tsv
//     KIND: vits | matcha | kitten | supertonic | textvits (lexicon/jieba VITS: MeloTTS, AISHELL-3)
//     -m MODEL -t TOKENS -v VOCODER|VOICES -l LEXICON -d DICT_DIR -S SUPERTONIC_DIR
//     -j THREADS -s SID -n STEPS -L LANG -r REPEAT -o OUTDIR
//
// Output: one JSON line per line and repetition on stdout.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "c-api.h"

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

static double t_start, t_first;
static int32_t on_audio(const float *s, int32_t n, float p, void *arg) {
  (void)s; (void)p; (void)arg;
  if (n > 0 && t_first == 0) t_first = now();
  return 1;
}

// UTF-8 to code points; '|' separates sentences.
static int utf8_sentences(const char *s, int32_t **cp, int32_t **lens) {
  size_t n = strlen(s);
  *cp = malloc(sizeof(int32_t) * (n + 1));
  *lens = malloc(sizeof(int32_t) * (n + 1));
  int k = 0, ns = 0, cur = 0;
  for (size_t i = 0; i < n;) {
    unsigned c = (unsigned char)s[i];
    int32_t u;
    int len;
    if (c < 0x80) { u = c; len = 1; }
    else if ((c >> 5) == 6) { u = c & 0x1f; len = 2; }
    else if ((c >> 4) == 14) { u = c & 0x0f; len = 3; }
    else { u = c & 0x07; len = 4; }
    for (int j = 1; j < len && i + j < n; j++) u = (u << 6) | ((unsigned char)s[i + j] & 0x3f);
    i += len;
    if (u == '|') {
      if (cur) (*lens)[ns++] = cur;
      cur = 0;
      continue;
    }
    (*cp)[k++] = u;
    cur++;
  }
  if (cur) (*lens)[ns++] = cur;
  return ns;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: rt-bench KIND [options] LINES.tsv\n");
    return 2;
  }
  const char *kind = argv[1], *m = "", *t = "", *v = "", *lx = "", *dd = "", *S = "", *lang = "", *out = NULL;
  int threads = 6, sid = 0, steps = 0, repeat = 1;
  const char *lines = NULL;
  for (int i = 2; i < argc; i++) {
    const char *a = argv[i];
    const char *val = i + 1 < argc ? argv[i + 1] : "";
    if (!strcmp(a, "-m")) m = val, i++;
    else if (!strcmp(a, "-t")) t = val, i++;
    else if (!strcmp(a, "-v")) v = val, i++;
    else if (!strcmp(a, "-l")) lx = val, i++;
    else if (!strcmp(a, "-d")) dd = val, i++;
    else if (!strcmp(a, "-S")) S = val, i++;
    else if (!strcmp(a, "-j")) threads = atoi(val), i++;
    else if (!strcmp(a, "-s")) sid = atoi(val), i++;
    else if (!strcmp(a, "-n")) steps = atoi(val), i++;
    else if (!strcmp(a, "-L")) lang = val, i++;
    else if (!strcmp(a, "-r")) repeat = atoi(val), i++;
    else if (!strcmp(a, "-o")) out = val, i++;
    else lines = a;
  }
  SherpaOnnxOfflineTtsConfig c;
  memset(&c, 0, sizeof c);
  c.model.num_threads = threads;
  c.model.provider = "cpu";
  c.max_num_sentences = 1;
  char sp[8][512];
  int phon = 0;
  if (!strcmp(kind, "vits") || !strcmp(kind, "textvits")) {
    c.model.vits.model = m;
    c.model.vits.tokens = t;
    c.model.vits.lexicon = lx;
    c.model.vits.dict_dir = dd;
    c.model.vits.noise_scale = 0.667f;
    c.model.vits.noise_scale_w = 0.8f;
    c.model.vits.length_scale = 1.0f;
    phon = !strcmp(kind, "vits");
  } else if (!strcmp(kind, "matcha")) {
    c.model.matcha.acoustic_model = m;
    c.model.matcha.vocoder = v;
    c.model.matcha.tokens = t;
    c.model.matcha.noise_scale = 0.667f;
    c.model.matcha.length_scale = 1.0f;
    phon = 1;
  } else if (!strcmp(kind, "kitten")) {
    c.model.kitten.model = m;
    c.model.kitten.voices = v;
    c.model.kitten.tokens = t;
    c.model.kitten.length_scale = 1.0f;
    phon = 1;
  } else if (!strcmp(kind, "supertonic")) {
    const char *names[] = {"duration_predictor", "text_encoder", "vector_estimator", "vocoder"};
    const char **dst[] = {&c.model.supertonic.duration_predictor, &c.model.supertonic.text_encoder,
                          &c.model.supertonic.vector_estimator, &c.model.supertonic.vocoder};
    for (int i = 0; i < 4; i++) {
      snprintf(sp[i], sizeof sp[i], "%s/%s.int8.onnx", S, names[i]);
      *dst[i] = sp[i];
    }
    snprintf(sp[4], 512, "%s/tts.json", S);
    snprintf(sp[5], 512, "%s/unicode_indexer.bin", S);
    snprintf(sp[6], 512, "%s/voice.bin", S);
    c.model.supertonic.tts_json = sp[4];
    c.model.supertonic.unicode_indexer = sp[5];
    c.model.supertonic.voice_style = sp[6];
  } else {
    fprintf(stderr, "rt-bench: unknown kind %s\n", kind);
    return 2;
  }
  long rss0 = status_kib("VmRSS:");
  double t0 = now();
  const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&c);
  if (!tts) {
    fprintf(stderr, "rt-bench: could not load the model\n");
    return 1;
  }
  fprintf(stderr, "rt-bench: loaded in %.2f s, rss %ld -> %ld KiB\n", now() - t0, rss0, status_kib("VmRSS:"));
  char extra[128];
  snprintf(extra, sizeof extra, "{\"lang\":\"%s\"}", lang);
  FILE *f = fopen(lines, "r");
  char *ln = NULL;
  size_t cap = 0;
  int warmed = 0;
  while (f && getline(&ln, &cap, f) > 0) {
    ln[strcspn(ln, "\r\n")] = 0;
    if (!*ln || *ln == '#') continue;
    char *fld[4] = {0};
    int nf = 0;
    for (char *p = ln; nf < 4;) {
      fld[nf++] = p;
      char *tab = strchr(p, '\t');
      if (!tab) break;
      *tab = 0;
      p = tab + 1;
    }
    if (nf < 3) continue;
    SherpaOnnxGenerationConfig g;
    memset(&g, 0, sizeof g);
    g.speed = 1.0f;
    g.silence_scale = 0.2f;
    g.sid = sid;
    g.num_steps = steps;
    g.extra = *lang ? extra : NULL;
    int32_t *cp = NULL, *lens = NULL;
    if (phon) {
      if (nf < 4) continue;
      g.phoneme_codepoints_num_sentences = utf8_sentences(fld[3], &cp, &lens);
      g.phoneme_codepoints = cp;
      g.phoneme_codepoints_lens = lens;
    }
    for (int r = (warmed ? 0 : -1); r < repeat; r++) {
      t_first = 0;
      t_start = now();
      const SherpaOnnxGeneratedAudio *a = SherpaOnnxOfflineTtsGenerateWithConfig(tts, fld[2], &g, on_audio, NULL);
      double dt = now() - t_start;
      if (!a) {
        fprintf(stderr, "rt-bench: %s: failed\n", fld[0]);
        break;
      }
      double secs = (double)a->n / a->sample_rate;
      if (r >= 0)
        printf("{\"id\":\"%s\",\"rep\":%d,\"audio_s\":%.3f,\"synth_s\":%.3f,\"rtf\":%.3f,\"first_s\":%.3f,\"rate\":%d,\"rss_kib\":%ld,\"hwm_kib\":%ld}\n",
               fld[0], r, secs, dt, dt / secs, t_first ? t_first - t_start : dt, a->sample_rate, status_kib("VmRSS:"), status_kib("VmHWM:"));
      fflush(stdout);
      if (r == 0 && out) {
        char path[1024];
        snprintf(path, sizeof path, "%s/%s.wav", out, fld[0]);
        SherpaOnnxWriteWave(a->samples, a->n, a->sample_rate, path);
      }
      SherpaOnnxDestroyOfflineTtsGeneratedAudio(a);
      warmed = 1;
    }
    free(cp);
    free(lens);
  }
  SherpaOnnxDestroyOfflineTts(tts);
  return 0;
}
