[![Actions Status](https://github.com/neb-abera/modern-cpp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-cpp-template/actions)

# Modern C++ Template

This is a modified version of [filipdutescu's modern-cpp-template](https://github.com/filipdutescu/modern-cpp-template/tree/master).

A quick C++ template for modern CMake projects, aimed to be an easy to use
starting point.

This is my personal take on such a type of template, thus I might not use the
best practices or you might disagree with how I do things. Any and all feedback
is greatly appreciated!

## Features

* Modern **CMake** configuration and project, which, to the best of my
knowledge, uses the best practices — targets C++26 by default (configurable
through the `CXX_STANDARD` option) and installs headers through CMake
[file sets](https://cmake.org/cmake/help/latest/command/target_sources.html),

* **CMake Presets** (`CMakePresets.json`) providing `debug`, `release`,
`coverage`, `asan` (Address + UB sanitizers) and `vcpkg` configurations, so
building is a consistent `cmake --preset <name>` on every platform and in CI,

* An example of a **Clang-Format** config, inspired from the base *Google* model,
with minor tweaks. This is aimed only as a starting point, as coding style
is a subjective matter, everyone is free to either delete it (for the *LLVM*
default) or supply their own alternative,

* **Static analyzers** integration, with *Clang-Tidy* and *Cppcheck*, the former
being the default option,

* **Doxygen** support, through the `ENABLE_DOXYGEN` option, which you can enable
if you wish to use it,

* **Unit testing** support, through *GoogleTest* (with an option to enable
*GoogleMock*) or *Catch2 v3*. The framework is resolved automatically: a
system-installed copy is used when found, and otherwise it is fetched at
configure time with `FetchContent` — no manual installation needed, locally
or in CI. Individual test cases are registered with CTest via
`gtest_discover_tests`/`catch_discover_tests`,

* **Code coverage**, enabled by using the `coverage` preset (or the
`ENABLE_CODE_COVERAGE` option), uploaded through the *Codecov* CI integration,

* **Package manager support**, with *vcpkg* (manifest mode, see `vcpkg.json`)
and *Conan 2* (see `conanfile.txt`),

* **CI workflows for Windows, Linux and macOS** as a single matrix using
*GitHub Actions*, with builds treating **warnings as errors**, a dedicated
**ASan + UBSan sanitizer job**, a **clang-format check**, and a **coverage
job** — so a green run means the change built cleanly, passed every test
(including under sanitizers) and is formatted, before it can merge. An
automated **release workflow** packages the install tree for all three
platforms and publishes a GitHub Release on tags,

* **Dockerized development environment** — a toolchain image pinning every
compiler and tool the project uses, with `make shell` for day-to-day
development inside the container and `make verify-docker` for a full
host-independent verification run, eliminating dependency drift between
developer machines and deployment servers,

* **.md templates** for: *README*, *Contributing Guideliness*,
*Issues* and *Pull Requests*,

* **Permissive license** to allow you to integrate it as easily as possible. The
template is licensed under the [Unlicense](https://unlicense.org/),

* Options to build as a header-only library or executable, not just a static or
shared library,

* **Ccache** integration, for speeding up rebuild times.

## Getting Started

These instructions will get you a copy of the project up and running on your local
machine for development and testing purposes.

### Prerequisites

**The intended development environment is the project's Docker container.**
Every tool the project needs — GCC 15 and Clang 21, CMake 4.2, clang-format, clang-tidy,
cppcheck, Doxygen, ccache, Conan 2 and vcpkg — is pinned in the
[`Dockerfile`](Dockerfile), so every developer (and CI) builds with the same
toolchain and "works on my machine" dependency drift between workstations and
deployment servers disappears. For that workflow you only need:

* **Docker** - found at [https://www.docker.com/](https://www.docker.com/)
* **git**

If you prefer to develop directly on your machine instead, you will need:

* **CMake v3.28+** - found at [https://cmake.org/](https://cmake.org/)

* **C++ Compiler** - needs to support at least the **C++26** standard: **GCC 14+**, **Clang 17+**, or a current **MSVC** (which builds C++26 as `/std:c++latest`)
(the standard can be lowered to C++17/20/23 through the
`<project_name>_CXX_STANDARD` option)

> ***Note:*** *You also need to be able to provide ***CMake*** a supported
[generator](https://cmake.org/cmake/help/latest/manual/cmake-generators.7.html).*

### Installing

It is fairly easy to install the project, all you need to do is clone if from
[GitHub](https://github.com/neb-abera/modern-cpp-template) or
[generate a new repository from it](https://github.com/neb-abera/modern-cpp-template/generate)
(also on **GitHub**).

If you wish to clone the repository, rather than generate from it, you simply need
to run:

```bash
git clone https://github.com/neb-abera/modern-cpp-template/
```

After finishing getting a copy of the project, with any of the methods above, create
a new folder in the `include/` folder, with the name of your project.  Edit
`cmake/SourcesAndHeaders.cmake` to add your files.

You will also need to rename the `cmake/ProjectConfig.cmake.in` file to start with
the ***exact name of your project***. Such as `cmake/MyNewProjectConfig.cmake.in`.

Finally, change `"Project"` from `CMakeLists.txt`, from

```cmake
project(
  "Project"
  VERSION 0.1.0
  LANGUAGES CXX
)
```

to the ***exact name of your project***, i.e. using the previous name it will become:

```cmake
project(
  MyNewProject
  VERSION 0.1.0
  LANGUAGES CXX
)
```

Project options are prefixed with the project name (i.e.
`MyNewProject_ENABLE_ASAN`), so after renaming you should also update the
`Project_*` cache variables referenced in `CMakePresets.json` and the `docs`
target in the `Makefile`.

To install an already built project, you need to run:

```bash
cmake --install build/release --prefix /absolute/path/to/custom/install/directory
```

## Building the project

### In Docker (recommended)

Open a development shell inside the toolchain container — the image is built
automatically the first time (cached afterwards) and your checkout is mounted
at `/work`, so you edit files on your machine with your normal editor and
build/test inside the container:

```bash
make shell
```

Everything below (presets, tests, docs, verification) works identically inside
that shell. The container is removed when you exit; only the image persists.

> ***Note:*** *Don't mix host builds and container builds in the same `build/`
directory — the CMake cache records absolute compiler paths. If you switch
between the two, `rm -rf build/` first.*

You can also run the full verification suite non-interactively in a fresh
container (source mounted read-only, checkout never touched):

```bash
make verify-docker
```

### The build itself

The project ships with [CMake presets](https://cmake.org/cmake/help/latest/manual/cmake-presets.7.html),
so building is the same everywhere — inside the container or on a host with
the prerequisites installed:

```bash
cmake --preset release        # configure (see `cmake --list-presets` for more)
cmake --build --preset release
```

Available configure presets are `debug`, `release`, `coverage`, `asan` and
`vcpkg`; each writes its build tree to `build/<preset>`. You can still use the
classic `cmake -B build ...` workflow if you prefer, and personal overrides
belong in a (git-ignored) `CMakeUserPresets.json`.

More options that you can set for the project can be found in the
[`cmake/StandardSettings.cmake` file](cmake/StandardSettings.cmake).

### Dependencies (package managers)

Dependencies can be consumed through either of two package managers, both using
the standard `find_package`/`target_link_libraries` flow in `CMakeLists.txt`:

* **vcpkg (manifest mode):** add your dependencies to [`vcpkg.json`](vcpkg.json),
set the `VCPKG_ROOT` environment variable to your [vcpkg](https://github.com/microsoft/vcpkg)
checkout and configure with the `vcpkg` preset:

```bash
cmake --preset vcpkg
```

* **Conan 2:** add your dependencies to [`conanfile.txt`](conanfile.txt), then
either use the [cmake-conan](https://github.com/conan-io/cmake-conan) dependency
provider or run `conan install` yourself — both are documented at the top of
`conanfile.txt`.

## Generating the documentation

In order to generate documentation for the project, you need to configure the build
to use Doxygen. This is easily done, by modifying the workflow shown above as follows:

```bash
cmake --preset release -D<project_name>_ENABLE_DOXYGEN=1
cmake --build --preset release --target doxygen-docs
```

> ***Note:*** *This will generate a `docs/` directory in the **project's root directory**.*

## Running the tests

By default, the template uses [GoogleTest](https://github.com/google/googletest/)
for unit testing (with [Catch2 v3](https://github.com/catchorg/Catch2) available
through the `USE_CATCH2` option). The framework is downloaded automatically at
configure time if it is not already installed. Unit testing can be disabled in
the options, by setting the `ENABLE_UNIT_TESTING` option (from
[cmake/StandardSettings.cmake](cmake/StandardSettings.cmake)) to false.

To run the tests, use CTest through the matching test preset:

```bash
ctest --preset release
```

To run the **full verification suite** — clean release build with
warnings-as-errors, tests under sanitizers, strict-standard-mode check,
executable smoke test, install-tree purity, a mutation canary proving the
tests catch planted bugs, and a clang-format check — with a running pass/fail
tally and a final summary:

```bash
make verify        # or directly: ./scripts/verify.sh
```

To run the same suite **inside a Docker container** — so results do not depend
on the compilers, CMake or clang-format versions installed on your machine —
use the project's toolchain image (built automatically from the
[`Dockerfile`](Dockerfile) on first run; the source tree is mounted read-only,
so your checkout is never touched):

```bash
make verify-docker # or directly: ./scripts/verify-docker.sh
```

### End to end tests

If applicable, should be presented here.

### Coding style tests

If applicable, should be presented here.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our how you can
become a contributor and the process for submitting pull requests to us.

## Versioning

This project makes use of [SemVer](http://semver.org/) for versioning. A list of
existing versions can be found in the
[project's releases](https://github.com/neb-abera/modern-cpp-template/releases).
Pushing a `v*` tag triggers the release workflow, which builds and tests on all
three platforms and publishes packaged install trees to a GitHub Release.

## Authors

* **Filip-Ioan Dutescu** - [@filipdutescu](https://github.com/filipdutescu)

## License

This project is licensed under the [Unlicense](https://unlicense.org/) - see the
[LICENSE](LICENSE) file for details
