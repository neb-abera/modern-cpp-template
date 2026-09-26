# Prose linter, for scripts/check-prose.sh. Never built into anything: the
# stage exists so the image is a FROM line Dependabot sees and bumps, and the
# script reads it from here rather than pinning a version of its own.
FROM jdkato/vale:v3.22.0@sha256:0ef74c2c8331a2cc8739ecc8b4f7cc6672e61524c3697e8c8857bc86b724a28e AS vale

# Workflow and script linters, for scripts/lint.sh, which builds this stage
# alone (`--target lint`). Both tools are FROM lines Dependabot sees and
# bumps. shellcheck is copied over the one the actionlint image bundles, so
# its version is the pin below and not whatever that image shipped with.
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck
FROM rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 AS lint
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck

# GCC, the newest release. Ubuntu 26.04 ships GCC 15 and only a GCC 16 dev
# snapshot. The Docker Official Image builds the GNU release into
# /usr/local, which the toolchain stage copies. Dependabot bumps this line,
# majors included.
FROM gcc:16.2.0@sha256:ef558a40d1f13115293feee01526dbdb9aaad7c9c5a00da05f471ce042e855c1 AS gcc
# The image also builds Go and Fortran, which nothing here uses.
RUN rm -rf /usr/local/bin/*go* /usr/local/bin/*gfortran* /usr/local/lib/go \
        /usr/local/lib64/libgo* /usr/local/lib64/libgfortran* \
        /usr/local/libexec/gcc/*/*/go1 /usr/local/libexec/gcc/*/*/f951 \
        /usr/local/libexec/gcc/*/*/cgo /usr/local/libexec/gcc/*/*/vet \
        /usr/local/libexec/gcc/*/*/buildid /usr/local/libexec/gcc/*/*/test2json

# LLVM, the newest release. Ubuntu 26.04 ships LLVM 21 and apt.llvm.org
# serves branch snapshots, so the tools come from the release tarball,
# checked against the SHA-256 GitHub records for it. Only the tools the
# gates use are kept. Clang takes its C++ standard library from the GCC
# above, not the older one Ubuntu's cbmc package pulls in.
# scripts/check-newest-llvm.sh fails when a newer release has been out 30
# days, and --update moves both lines.
FROM ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78 AS llvm
ENV LLVM_VERSION=23.1.2
ENV LLVM_SHA256=6382de1c1a210ce5a5cc49d18bc8444d137742e7cbf9b19f4ae602bb1ab52534
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl zstd && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/llvm.tar.zst \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-Linux-X64.tar.zst" && \
    echo "${LLVM_SHA256}  /tmp/llvm.tar.zst" | sha256sum -c - && \
    mkdir /opt/llvm && \
    zstd --long=30 -dc /tmp/llvm.tar.zst | tar -x -C /opt/llvm --strip-components=1 --wildcards \
        '*/bin/clang' '*/bin/clang++' '*/bin/clang-[0-9]*' \
        '*/bin/clang-tidy' '*/bin/run-clang-tidy' '*/bin/clang-apply-replacements' \
        '*/bin/clang-format' '*/bin/git-clang-format' \
        '*/bin/llvm-symbolizer' '*/bin/llvm-cov' '*/bin/llvm-profdata' \
        '*/lib/clang/*' && \
    rm /tmp/llvm.tar.zst && \
    printf '%s\n' '--gcc-toolchain=/usr/local' > /opt/llvm/bin/clang.cfg && \
    cp /opt/llvm/bin/clang.cfg /opt/llvm/bin/clang++.cfg

# Pinned by digest so every build resolves the same base image; Dependabot's
# docker ecosystem keeps the digest current. 26.04 LTS digest as of 2026-08-30.
FROM ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78

# Base toolchain: GCC and LLVM from the stages above, CMake 4.2 from Ubuntu.
# The unit testing frameworks (GoogleTest/Catch2) are fetched by CMake via
# FetchContent, so they are not installed here.
# The pinned CBMC version, for the proof gate (scripts/check-proofs.sh).
# CBMC is a model checker carrying its own SAT solver, and a proof is only as
# good as the solver that checked it, so the gate fails when the installed
# version and this line disagree. On a Dependabot base image bump the
# Dependabot toolchain pins workflow moves this line with scripts/sync-cbmc.sh.
ENV CBMC_VERSION=6.6.0

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        build-essential \
        cbmc \
        ccache \
        cmake \
        cppcheck \
        curl \
        doxygen \
        gcovr \
        git \
        graphviz \
        ninja-build \
        pipx \
        python3 \
        python3-yaml \
        tar \
        unzip \
        zip \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Remove pebble, an unused service manager shipped in the base image whose
# bundled Go stdlib periodically trips CVE scanners
RUN rm -f /usr/bin/pebble

# GCC 16 in /usr/local, ahead of Ubuntu's GCC 15 on PATH and in the loader
# cache, so programs it builds load its libstdc++.
COPY --from=gcc /usr/local/ /usr/local/
RUN echo /usr/local/lib64 > /etc/ld.so.conf.d/000-gcc.conf && ldconfig
COPY --from=llvm /opt/llvm/ /opt/llvm/
ENV PATH="/opt/llvm/bin:$PATH" CC=gcc CXX=g++

# vcpkg (optional package manager), used in manifest mode via the `vcpkg`
# CMake preset; owned by the non-root user below so it can install ports.
# Pinned to the commit of the vcpkg 2026.07.29 release rather than floating
# at HEAD; bump the SHA and this version comment together when updating.
RUN git init -q /opt/vcpkg && \
    git -C /opt/vcpkg fetch --depth 1 https://github.com/microsoft/vcpkg \
        9e593bb18ea69cc5095e012465dcd675a822ed0d && \
    git -C /opt/vcpkg checkout -q FETCH_HEAD && \
    /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics && \
    chown -R ubuntu:ubuntu /opt/vcpkg
ENV VCPKG_ROOT=/opt/vcpkg

# Run as the image's non-root 'ubuntu' user (uid 1000) rather than root
USER ubuntu
WORKDIR /home/ubuntu
# `make shell` runs as the host user, who may not be uid 1000. Opening this
# home lets that user reach Conan in ~/.local/bin. Nothing secret lives here.
RUN chmod 755 /home/ubuntu

# Conan 2 (optional package manager), isolated via pipx; its venv's
# setuptools/msgpack are upgraded past known CVEs
RUN pipx install conan==2.31.2 && \
    pipx runpip conan install --quiet --upgrade setuptools msgpack
ENV PATH="/home/ubuntu/.local/bin:$PATH"
