# Prose linter, for scripts/check-prose.sh. Never built into anything: the
# stage exists so the image is a FROM line Dependabot sees and bumps, and the
# script reads it from here rather than pinning a version of its own.
FROM jdkato/vale:v3.22.0@sha256:0ef74c2c8331a2cc8739ecc8b4f7cc6672e61524c3697e8c8857bc86b724a28e AS vale

# The scanners CI runs, for their versions only: trivy-action and
# sbom-action take a version input, and these FROM lines are what
# Dependabot bumps. Nothing is built from them.
FROM aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969 AS trivy

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
# above, not the older one Ubuntu's build-essential pulls in.
# scripts/check-newest-pins.py fails when a newer release has been out 30
# days, and --update moves both lines. It covers every pin below that names
# a GitHub release: LLVM, Doxygen, CBMC and vcpkg.
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

# Doxygen, the newest release. Ubuntu ships 1.15, so the binary comes from
# the release's Linux tarball, checked against the SHA-256 GitHub records.
FROM llvm AS doxygen
ENV DOXYGEN_VERSION=1.18.0
ENV DOXYGEN_SHA256=14fa81bdc34171edb5f1f02b1d60e74802f0439b77fa44e592565d517d72df90
RUN curl -fsSL -o /tmp/doxygen.tar.gz \
        "https://github.com/doxygen/doxygen/releases/download/Release_$(echo "$DOXYGEN_VERSION" | tr . _)/doxygen-${DOXYGEN_VERSION}.linux.bin.tar.gz" && \
    echo "${DOXYGEN_SHA256}  /tmp/doxygen.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/doxygen.tar.gz -C /tmp "doxygen-${DOXYGEN_VERSION}/bin/doxygen" && \
    install -D -m 755 "/tmp/doxygen-${DOXYGEN_VERSION}/bin/doxygen" /opt/doxygen/doxygen && \
    rm -rf /tmp/doxygen*

# Pinned by digest so every build resolves the same base image; Dependabot's
# docker ecosystem keeps the digest current. 26.10 is the development
# release, taken because the full suite is green on it.
FROM ubuntu:26.10@sha256:ee126c2fa0249079a7e24ae3a3d29b04783ef93ab33c868751c9a1289d3fffff

# Base toolchain: GCC, LLVM and Doxygen from the stages above, CBMC from its
# release, CMake, Conan and gcovr from PyPI, the rest from Ubuntu. The unit
# testing frameworks (GoogleTest/Catch2) are fetched by CMake via
# FetchContent, so they are not installed here.

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        cppcheck \
        curl \
        git \
        graphviz \
        ninja-build \
        python3 \
        python3-venv \
        python3-yaml \
        tar \
        unzip \
        zip \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Remove pebble, an unused service manager shipped in the base image whose
# bundled Go stdlib periodically trips CVE scanners
RUN rm -f /usr/bin/pebble

# CBMC, the newest release, for the proof gate (scripts/check-proofs.sh).
# Ubuntu's archive ships 6.6.0, so it comes from the release's .deb, checked
# against the SHA-256 GitHub records. CBMC carries its own SAT solver, and a
# proof is only as good as the solver that checked it, so the gate fails
# when the installed version and CBMC_VERSION disagree.
ENV CBMC_VERSION=6.11.0
ENV CBMC_SHA256=b3721aa541038384d7801ea3aeabbcddc3e8845ac8f1cbff637cf8dec7481ac8
RUN curl -fsSL -o /tmp/cbmc.deb \
        "https://github.com/diffblue/cbmc/releases/download/cbmc-${CBMC_VERSION}/ubuntu-24.04-cbmc-${CBMC_VERSION}-Linux.deb" && \
    echo "${CBMC_SHA256}  /tmp/cbmc.deb" | sha256sum -c - && \
    apt-get update && \
    apt-get install -y --no-install-recommends /tmp/cbmc.deb && \
    rm -rf /tmp/cbmc.deb /var/lib/apt/lists/*

# CMake, Conan and gcovr, the newest releases, from PyPI into one venv.
# tools/python/requirements.txt pins each with a hash for every artifact,
# and Dependabot's pip ecosystem bumps it.
COPY tools/python/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/pytools && \
    /opt/pytools/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt
ENV PATH="/opt/pytools/bin:$PATH"

COPY --from=doxygen /opt/doxygen/doxygen /usr/local/bin/doxygen

# GCC 16 in /usr/local, ahead of Ubuntu's GCC 15 on PATH and in the loader
# cache, so programs it builds load its libstdc++.
COPY --from=gcc /usr/local/ /usr/local/
RUN echo /usr/local/lib64 > /etc/ld.so.conf.d/000-gcc.conf && ldconfig
COPY --from=llvm /opt/llvm/ /opt/llvm/
ENV PATH="/opt/llvm/bin:$PATH" CC=gcc CXX=g++

# vcpkg (optional package manager), used in manifest mode via the `vcpkg`
# CMake preset; owned by the non-root user below so it can install ports.
# Pinned to the commit of a release tag; scripts/check-newest-pins.py moves
# both lines.
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
