"""Stands in for kokoro.KPipeline in Paradee's training scripts: the teacher
is Kokoro-82M v1.0 from KOKORO_DIR (default /w/downloads/hexgrad) built with
kokoro_pkg's KModel, and every voice it is asked for is PARADEE_VOICE (a
name or a blend "jf_alpha*0.7+af_heart*0.3"), so the scripts' hard-coded
"af_heart" loads our teacher voice. g2p returns phonemes from
PARADEE_G2P_TSV (our front end's output), one line per call, cycling: the
upstream scripts only use it for a few fixed demo sentences."""
import os, torch
from kokoro.model import KModel

KDIR = os.environ.get("KOKORO_DIR", "/w/downloads/hexgrad")


def voice_pack(spec):
    parts = []
    for p in spec.split("+"):
        n, w = (p.split("*") + ["1"])[:2]
        parts.append((torch.load(os.path.join(KDIR, "voices", f"{n.strip()}.pt"), weights_only=True), float(w)))
    tot = sum(w for _, w in parts)
    return sum(v * (w / tot) for v, w in parts)


class KPipeline:
    def __init__(self, lang_code="a", device="cpu", repo_id=None, **kw):
        self.model = KModel(config=os.path.join(KDIR, "config.json"), model=os.path.join(KDIR, "kokoro-v1_0.pth")).to(device).eval()
        self.voice = os.environ.get("PARADEE_VOICE", "af_heart")
        self._ps, self._k = [], 0
        p = os.environ.get("PARADEE_G2P_TSV")
        if p and os.path.exists(p):
            self._ps = [l.rstrip("\n").split("\t")[2] for l in open(p, encoding="utf-8") if l.count("\t") >= 2]

    def load_voice(self, name):
        return voice_pack(self.voice)

    def g2p(self, text):
        if not self._ps:
            raise RuntimeError("PARADEE_G2P_TSV is not set")
        ps = self._ps[self._k % len(self._ps)]
        self._k += 1
        return ps, None
