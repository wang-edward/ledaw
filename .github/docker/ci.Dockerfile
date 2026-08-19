FROM rust:1.95.0-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        libasound2-dev \
        libclang-dev \
        libgl1-mesa-dev \
        libx11-dev \
        libxcursor-dev \
        libxi-dev \
        libxinerama-dev \
        libxrandr-dev \
        pkg-config \
        xauth \
        xvfb \
    && rustup component add clippy rustfmt \
    && rm -rf /var/lib/apt/lists/*
