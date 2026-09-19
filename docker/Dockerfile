# Build environment for the Linux slices. It starts from the same Swift image that consumers
# build ChromaticKit in, so the static archives are compiled against the glibc and libstdc++
# that a `swift build` on that image links. clang and pkg-config already come with the image;
# the rest is what Skia's gn/ninja build and the fontconfig font manager need.
ARG BASE_IMAGE=swift:6.2-noble
FROM ${BASE_IMAGE}
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    binutils \
    ca-certificates \
    git \
    libfontconfig-dev \
    ninja-build \
    python3 \
  && rm -rf /var/lib/apt/lists/*
