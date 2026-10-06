# Prose linter, for scripts/check-prose.sh. Never built into anything: the
# stage exists so the image is a FROM line Dependabot sees and bumps, and the
# script reads it from here rather than pinning a version of its own.
FROM jdkato/vale:v3.23.0@sha256:d87d6355dc8992f92ec39c4c862a388e56e30302a771fd4512c02660fb25cdf3 AS vale

# The scanners CI runs, for their versions only: trivy-action and
# sbom-action take a version input, and these FROM lines are what
# Dependabot bumps. Nothing is built from them.
FROM aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa AS trivy

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
# above, not the older one the cbmc package pulls in.
# scripts/check-newest-releases.sh fails when a newer release has been out 30
# days, and --update moves both lines.
FROM ubuntu:26.10@sha256:ee126c2fa0249079a7e24ae3a3d29b04783ef93ab33c868751c9a1289d3fffff AS llvm
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

# CMake, CBMC, ccache and Doxygen, the newest releases. Ubuntu 26.10 ships
# CMake 4.3, CBMC 6.6, ccache 4.13 and Doxygen 1.15. Each file is the one the
# project's GitHub release publishes, checked against the SHA-256 GitHub
# records for it. scripts/check-newest-releases.sh fails when a newer release
# has been out 30 days, and --update moves the pins.
FROM ubuntu:26.10@sha256:ee126c2fa0249079a7e24ae3a3d29b04783ef93ab33c868751c9a1289d3fffff AS tools
ENV CMAKE_VERSION=4.4.3
ENV CMAKE_SHA256=d6c83076c575bc00b823522ac974bda66d0af05d6ddc30e739c12385cf32c6cc
ENV CBMC_VERSION=6.11.0
ENV CBMC_SHA256=b3721aa541038384d7801ea3aeabbcddc3e8845ac8f1cbff637cf8dec7481ac8
ENV CCACHE_VERSION=4.14
ENV CCACHE_SHA256=45a91165db7092e67c6208ada03f54700e684c4cd3735f9031de95669ed9272c
ENV DOXYGEN_VERSION=1.18.0
ENV DOXYGEN_SHA256=14fa81bdc34171edb5f1f02b1d60e74802f0439b77fa44e592565d517d72df90
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils && \
    rm -rf /var/lib/apt/lists/*
RUN set -e; \
    get() { curl -fsSL -o "$1" "$2" && echo "$3  $1" | sha256sum -c -; }; \
    get /tmp/cmake.tar.gz \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" \
        "$CMAKE_SHA256"; \
    mkdir -p /opt/cmake && tar -xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1 \
        --exclude='*/doc' --exclude='*/man' --exclude='*/bin/cmake-gui'; \
    get /opt/cbmc.deb \
        "https://github.com/diffblue/cbmc/releases/download/cbmc-${CBMC_VERSION}/ubuntu-24.04-cbmc-${CBMC_VERSION}-Linux.deb" \
        "$CBMC_SHA256"; \
    get /tmp/ccache.tar.xz \
        "https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}-linux-x86_64-glibc.tar.xz" \
        "$CCACHE_SHA256"; \
    mkdir -p /opt/tools/bin && tar -xJf /tmp/ccache.tar.xz -C /opt/tools/bin --strip-components=1 --wildcards '*/ccache'; \
    get /tmp/doxygen.tar.gz \
        "https://github.com/doxygen/doxygen/releases/download/Release_$(echo "$DOXYGEN_VERSION" | tr . _)/doxygen-${DOXYGEN_VERSION}.linux.bin.tar.gz" \
        "$DOXYGEN_SHA256"; \
    tar -xzf /tmp/doxygen.tar.gz -C /opt/tools/bin --strip-components=2 --wildcards '*/bin/doxygen'; \
    rm /tmp/*.tar.*

# Pinned by digest so every build resolves the same base image; Dependabot's
# docker ecosystem keeps the digest current. 26.10 is the development
# release, taken because the full suite is green on it.
FROM ubuntu:26.10@sha256:ee126c2fa0249079a7e24ae3a3d29b04783ef93ab33c868751c9a1289d3fffff

# Base toolchain: GCC, LLVM, CMake, CBMC, ccache and Doxygen from the stages
# above. The unit testing frameworks (GoogleTest/Catch2) are fetched by CMake
# via FetchContent, so they are not installed here.
# CBMC is a model checker carrying its own SAT solver, and a proof is only as
# good as the solver that checked it, so scripts/check-proofs.sh fails when
# the installed version and the tools stage's ENV CBMC_VERSION disagree.
COPY --from=tools /opt/cbmc.deb /tmp/cbmc.deb
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        /tmp/cbmc.deb \
        build-essential \
        cppcheck \
        curl \
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
    rm -rf /var/lib/apt/lists/* /tmp/cbmc.deb

# Remove pebble, an unused service manager shipped in the base image whose
# bundled Go stdlib periodically trips CVE scanners
RUN rm -f /usr/bin/pebble

# GCC 16 in /usr/local, ahead of Ubuntu's GCC 15 on PATH and in the loader
# cache, so programs it builds load its libstdc++.
COPY --from=gcc /usr/local/ /usr/local/
RUN echo /usr/local/lib64 > /etc/ld.so.conf.d/000-gcc.conf && ldconfig
COPY --from=llvm /opt/llvm/ /opt/llvm/
COPY --from=tools /opt/cmake/ /opt/cmake/
COPY --from=tools /opt/tools/bin/ /usr/local/bin/
ENV PATH="/opt/llvm/bin:/opt/cmake/bin:$PATH" CC=gcc CXX=g++

# vcpkg (optional package manager), used in manifest mode via the `vcpkg`
# CMake preset; owned by the non-root user below so it can install ports.
# Pinned to the commit of a release tag. scripts/check-newest-releases.sh
# fails when a newer release has been out 30 days, and --update moves both
# lines.
ENV VCPKG_VERSION=2026.07.29
ENV VCPKG_COMMIT=9e593bb18ea69cc5095e012465dcd675a822ed0d
RUN git init -q /opt/vcpkg && \
    git -C /opt/vcpkg fetch --depth 1 https://github.com/microsoft/vcpkg "$VCPKG_COMMIT" && \
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

# Conan 2 (optional package manager) and gcovr (the coverage gate), each
# isolated via pipx at the version tools/python/requirements.txt pins, where
# Dependabot's pip ecosystem bumps it. Conan's venv's setuptools/msgpack are
# upgraded past known CVEs.
COPY --chown=ubuntu:ubuntu tools/python/requirements.txt /tmp/requirements.txt
RUN pipx install "$(grep -x 'conan==.*' /tmp/requirements.txt)" && \
    pipx install "$(grep -x 'gcovr==.*' /tmp/requirements.txt)" && \
    pipx runpip conan install --quiet --upgrade setuptools msgpack && \
    rm /tmp/requirements.txt
ENV PATH="/home/ubuntu/.local/bin:$PATH"
