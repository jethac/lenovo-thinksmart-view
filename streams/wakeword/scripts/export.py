"""Turn a training checkpoint into a model directory (hey-straylight.slt + .onnx).

    export.py CKPT.pt OUTDIR
"""
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train  # noqa: E402


def main():
    ck = torch.load(sys.argv[1], weights_only=False)
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    m = train.Head(ck["dim"], ck["blocks"]).cuda()
    m.load_state_dict(ck["state"])
    m.eval()
    train.export(m, out)
    torch.save(ck, out / "model.pt")
    print(f"{out}: step {ck['step']}")


if __name__ == "__main__":
    main()
