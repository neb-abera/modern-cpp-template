FROM ubuntu:24.04

RUN echo "Updating Ubuntu"
RUN apt-get update && apt-get upgrade -y

RUN echo "Installing dependencies..."
RUN apt install -y \
			ccache \
			clang \
			clang-format \
			clang-tidy \
			cppcheck \
			curl \
			doxygen \
			gcc \
			git \
			graphviz \
			make \
			ninja-build \
			python3 \
			python3-pip \
			tar \
			unzip \
			vim

RUN echo "Installing dependencies not found in the package repos..."

# Install the latest precompiled version of CMake
 RUN curl -s https://api.github.com/repos/Kitware/CMake/releases/latest | \
     grep "browser_download_url.*linux-x86_64.tar.gz" | \
     cut -d '"' -f 4 | \
     xargs curl -LO && \
     mkdir -p /opt/cmake && \
     tar --strip-components=1 -zxf cmake-*-linux-x86_64.tar.gz -C /opt/cmake && \
     ln -s /opt/cmake/bin/cmake /usr/bin/cmake && \
     ln -s /opt/cmake/bin/ctest /usr/bin/ctest && \
     ln -s /opt/cmake/bin/cpack /usr/bin/cpack && \
     rm cmake-*-linux-x86_64.tar.gz

# Install necessary Python system packages
RUN apt-get install -y python3-venv python3-dev python3-pip

# Create a virtual environment for Conan
RUN python3 -m venv /opt/conan-env && \
    /opt/conan-env/bin/pip install --upgrade pip && \
    /opt/conan-env/bin/pip install conan

# Ensure the environment is activated for Docker builds
ENV PATH="/opt/conan-env/bin:$PATH"

RUN git clone https://github.com/catchorg/Catch2.git && \
		 cd Catch2 && \
		 cmake -Bbuild -H. -DBUILD_TESTING=OFF && \
		 cmake --build build/ --target install

# Disabled pthread support for GTest due to linking errors
RUN git clone https://github.com/google/googletest.git && \
        cd googletest && \
        git checkout v1.14.0 && \
        cmake -Bbuild -Dgtest_disable_pthreads=1 && \
        cmake --build build --config Release && \
        cmake --build build --target install --config Release

RUN git clone https://github.com/microsoft/vcpkg -b 2020.06 && \
		cd vcpkg && \
		./bootstrap-vcpkg.sh -disableMetrics -useSystemBinaries	
