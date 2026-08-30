# Pinned by digest so every build resolves the same base image; Dependabot's
# docker ecosystem keeps the digest current. 26.04 LTS digest as of 2026-08-30.
FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

# Base toolchain. Ubuntu 26.04 LTS ships GCC 15 (full C++26 support),
# CMake 4.2 and the LLVM 21 tools, all well above the project's minimums,
# so no manual installs are needed. The unit testing frameworks
# (GoogleTest/Catch2) are fetched automatically by CMake via FetchContent,
# so they are not installed here either.
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        build-essential \
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

# Conan 2 (optional package manager), isolated via pipx; its venv's
# setuptools/msgpack are upgraded past known CVEs
RUN pipx install conan==2.31.2 && \
    pipx runpip conan install --quiet --upgrade setuptools msgpack
ENV PATH="/home/ubuntu/.local/bin:$PATH"
