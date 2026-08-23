FROM ubuntu:24.04

# Base toolchain. Ubuntu 24.04 ships CMake 3.28, which satisfies the
# project's 3.28 minimum, so no manual CMake install is needed. The unit
# testing frameworks (GoogleTest/Catch2) are fetched automatically by CMake
# via FetchContent, so they are not installed here either.
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        clang \
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
        tar \
        unzip \
        zip \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Conan 2 (optional package manager), isolated via pipx
RUN pipx install conan
ENV PATH="/root/.local/bin:$PATH"

# vcpkg (optional package manager), used in manifest mode via the `vcpkg`
# CMake preset
RUN git clone --depth 1 https://github.com/microsoft/vcpkg /opt/vcpkg && \
    /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
ENV VCPKG_ROOT=/opt/vcpkg
