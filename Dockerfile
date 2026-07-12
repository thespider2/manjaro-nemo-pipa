FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip coreutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY profiles /build/profiles
COPY scripts /build/scripts
COPY README.md Makefile /build/
RUN chmod +x /build/scripts/*.sh
ENV CI=1 OUT_DIR=/out
VOLUME ["/out"]
ENTRYPOINT ["/bin/bash", "/build/scripts/ci-build-image.sh"]
