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

# Pinned by digest so every build resolves the same base image; Dependabot's
# docker ecosystem keeps the digest current. 26.04 LTS digest as of 2026-08-30.
FROM ubuntu:26.04@sha256:513c074113a871b51a8d16ab445c88779d6452d937a164fb5cc479f32668a41d

# Base toolchain. Ubuntu 26.04 LTS ships GCC 15 (full C++26 support),
# CMake 4.2 and the LLVM 21 tools, all well above the project's minimums,
# so no manual installs are needed. The unit testing frameworks
# (GoogleTest/Catch2) are fetched automatically by CMake via FetchContent,
# so they are not installed here either.
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
        clang \
        libclang-rt-21-dev \
        libfuzzer-21-dev \
        clang-format \
        clang-tidy \
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
