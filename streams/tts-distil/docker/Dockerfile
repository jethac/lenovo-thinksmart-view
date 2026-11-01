# Training image for the distilled voices (PGX: aarch64, GB10).
FROM nvcr.io/nvidia/pytorch:26.10-py3
RUN pip install --no-cache-dir transformers==4.57.1 loguru soundfile librosa==0.11.0 soxr \
      lightning==2.5.5 hydra-core==1.3.2 hydra-colorlog rich einops inflect unidecode conformer==0.3.2 \
      diffusers==0.35.2 encodec==0.1.1 onnx onnxruntime matplotlib tensorboard pyyaml jsonargparse[signatures] \
      cython "numpy<2.3"
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir gdown wget seaborn phonemizer rootutils
