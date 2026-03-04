FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    jq \
    yq \
    ripgrep \
    diffutils \
    file \
    tar \
    gzip \
    zip \
    unzip \
    procps \
    psmisc \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
SHELL ["/bin/bash", "-lc"]
