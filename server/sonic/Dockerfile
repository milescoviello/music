FROM python:3.12-slim

# Essentia's TensorFlow build looks for an old CUDA and falls back to the CPU, which is
# plenty for a 3 MB model; this keeps it from saying so on every track.
ENV TF_CPP_MIN_LOG_LEVEL=3 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Opus, which Essentia's own decoder cannot read (analyse.FOREIGN_SUFFIXES). A layer of
# its own, so adding it did not rebuild the one above, whose unpinned packages a rebuild
# would move to newer versions than the ones Essentia runs with now.
RUN pip install --no-cache-dir soundfile==0.13.1
COPY sonic ./sonic

EXPOSE 8650
CMD ["python", "-m", "sonic", "serve"]
