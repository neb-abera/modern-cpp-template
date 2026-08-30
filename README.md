[![Actions Status](https://github.com/neb-abera/modern-cpp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-cpp-template/actions)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/neb-abera/modern-cpp-template/badge)](https://scorecard.dev/viewer/?uri=github.com/neb-abera/modern-cpp-template)

# Modern C++ Template

A production-shaped starting point for C++ projects: **C++26** by default,
**CMake presets**, developed entirely in Docker, gated by a test-driven
verification suite, and secured by default.

## Features

* **Docker-first development** — the host needs only Docker and git. `make
  shell` opens a toolchain shell (GCC 15, Clang 21, CMake 4.2, clang-format,
  clang-tidy, Doxygen, ccache, Conan 2, vcpkg — all pinned in the
  [`Dockerfile`](Dockerfile)); `make verify-docker` runs the whole suite in a
  fresh container with the source mounted read-only,

* **Modern CMake** — C++26 by default (configurable via the `CXX_STANDARD`
  option; MSVC auto-clamps to its newest mode until it ships one), headers
  installed through [file sets](https://cmake.org/cmake/help/latest/command/target_sources.html),
  library / header-only / executable modes, and
  [presets](https://cmake.org/cmake/help/latest/manual/cmake-presets.7.html)
  (`debug`, `release` with LTO, `coverage`, `asan`, `tsan`, `tidy`, `bench`,
  `fuzz`, `vcpkg`) so building is `cmake --preset <name>` everywhere,

* **Test-driven by default** — GoogleTest (or Catch2 v3) fetched
  automatically via `FetchContent` with a system-install fallback, individual
  cases registered with CTest via `gtest_discover_tests`, and a **mutation
  canary** proving the tests catch planted bugs,

* **One verification suite everywhere** — `make verify` runs twelve checks
  with a running pass/fail tally: release build+tests (warnings as errors),
  ASan+UBSan, TSan, clang-tidy, fuzz smoke, benchmark smoke, strict standard
  mode, executable smoke, install-tree purity (LICENSE and NOTICE included),
  the mutation canary, a required-contexts drift guard, and clang-format. CI
  gates on the identical suite **inside the production toolchain container**
  ("train as you fight"), plus gating macOS/Windows portability builds on
  native toolchains — warnings as errors on all three compilers,

* **Security by default** — OpenSSF compiler hardening plus the C++26
  hardened standard library on by default, CodeQL (C++ and workflows) on
  every PR, Actions pinned to commit SHAs, least-privilege tokens,
  harden-runner egress control, trivy image scanning, and a SECURITY.md
  (see it for the full inventory),

* **…and it stays current by machinery, not memory** — every Action and the
  Docker base image are pinned by commit SHA with a version comment, and
  Dependabot bumps SHA and comment together, minor/patch grouped into one
  weekly PR per ecosystem. The `dependabot-automerge` workflow arms
  auto-merge on every Dependabot PR, majors included; red CI, not update
  size, is the review signal,

* **Releases from tags** — pushing `v*` builds and tests on all three
  platforms and publishes packaged install trees (with SBOMs and provenance
  attestations) to a GitHub Release. Tag confirmed-working milestones so
  rollback points are named,

* **Ccache**, **Doxygen** (published to GitHub Pages on pushes to main), and
  a devcontainer for one-click IDE setup.

## Getting started

Generate a repository from this template on GitHub, clone it, then:

```bash
make shell          # toolchain shell: edit on the host, build in the container
```

```bash
make verify-docker  # the full verification suite (what CI runs)
```

Inside the shell (or on a host with the prerequisites), building is presets
all the way down:

```bash
cmake --preset release && cmake --build --preset release && ctest --preset release
```

`make help` lists everything else (`test`, `coverage`, `asan`, `bench`,
`docs`, `format`).

> ***Note:*** *Don't mix host builds and container builds in the same
`build/` directory — the CMake cache records absolute compiler paths. If you
switch between the two, `rm -rf build/` first.*

### Prerequisites

* **Docker** - found at [https://www.docker.com/](https://www.docker.com/)
* **git**

Nothing else for the intended workflow: compilers and every analysis tool run
inside the container. To develop directly on the host instead you need
**CMake 3.28+** and **GCC 14+ / Clang 17+** (or MSVC; the standard can be
lowered to C++17/20/23 via the `<project_name>_CXX_STANDARD` option).

## Project layout

```
include/          public headers, installed via CMake file sets
src/              implementation and the optional executable entry point
test/             GoogleTest suite, registered per-case with CTest
bench/            Google Benchmark harness (`bench` preset)
fuzz/             libFuzzer harness built with ASan+UBSan (`fuzz` preset)
cmake/            StandardSettings, CompilerWarnings, analyzers, install glue
scripts/          verify.sh / verify-docker.sh / setup.sh / check-required-contexts.sh
Dockerfile        the pinned toolchain image CI and `make shell` share
.github/          CI, CodeQL, Security scan, Docs and Release workflows (SHA-pinned), Dependabot
```

## Development workflow

1. Write a failing test in `test/` (or a fuzz/bench target when that layer
   owns the behavior).
2. `make shell` and implement until the test passes.
3. `make verify-docker` before pushing — CI gates on the identical suite, so
   a local green run predicts the PR gate.
4. When a milestone is confirmed working, tag it (`git tag v1.2.0 && git
   push origin v1.2.0`) to publish a release ([SemVer](http://semver.org/)).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the pull-request process.

### Dependencies (package managers)

Both package managers use the standard `find_package`/`target_link_libraries`
flow in `CMakeLists.txt`:

* **vcpkg (manifest mode):** add dependencies to [`vcpkg.json`](vcpkg.json),
  point `VCPKG_ROOT` at a [vcpkg](https://github.com/microsoft/vcpkg)
  checkout, and configure with `cmake --preset vcpkg`.
* **Conan 2:** add dependencies to [`conanfile.txt`](conanfile.txt); both the
  [cmake-conan](https://github.com/conan-io/cmake-conan) provider and plain
  `conan install` flows are documented at the top of that file.

### Documentation

```bash
make docs     # Doxygen into docs/html; CI publishes it to GitHub Pages on main
```

## Where the practices come from

The canon this template enforces, and the gate that enforces it — advice that
is not a failing check decays, so each source is wired to one:

* **C++ Core Guidelines** (Stroustrup/Sutter — the living successor to *C++
  Coding Standards*) and the **SEI CERT C++ standard** — enforced by
  clang-tidy's `cppcoreguidelines-*` and `cert-*` checks via the `tidy`
  preset, gated in CI, warnings as errors ([.clang-tidy](.clang-tidy)),
* **Effective (Modern) C++ / Effective STL** (Meyers) — the `modernize-*`,
  `performance-*`, `readability-*` and `bugprone-*` checks in the same gate,
* **C++ Concurrency in Action** (Williams) — the `tsan` preset runs the test
  suite under ThreadSanitizer in CI; `concurrency-*` clang-tidy checks run
  statically,
* **cppbestpractices** (Jason Turner) — the warning set in
  [CompilerWarnings.cmake](cmake/CompilerWarnings.cmake),
* **OpenSSF compiler hardening** plus the **C++26 hardened standard
  library** (`_GLIBCXX_ASSERTIONS` / libc++ hardening) — on by default in
  [StandardSettings.cmake](cmake/StandardSettings.cmake),
* memory errors and undefined behavior — Address + UndefinedBehavior
  sanitizer runs on every PR,
* **benchmarks** — a Google Benchmark harness ([bench/](bench/)) via the
  `bench` preset; a harness rather than a timing gate, because shared CI
  runners make numbers noise — CI proves it builds and runs,
* **fuzzing** — a libFuzzer harness ([fuzz/](fuzz/)) built with ASan+UBSan
  via the `fuzz` preset; CI smoke-runs it, and the harness is where a real
  project points the fuzzer at its parsers and input paths.

What a linter cannot check — naming things well, small functions, honest
tests (*Code Complete*, *Clean Code*, *Refactoring*) — is what the mutation
canary, the test-first workflow and code review are for.

## After generating from this template

One command finishes the setup — it renames the project after your
repository (CMake project name and option prefix, the `*Config.cmake.in`
file, presets, Makefile, the include directory and every `#include` of it,
and the README badge/links) and enables the repo-level GitHub settings
templates cannot carry over (secret scanning, push protection, private
vulnerability reporting, Dependabot alerts + security updates, GitHub Pages,
and branch protection requiring the gating CI checks):

```bash
./scripts/setup.sh
```

It needs the [GitHub CLI](https://cli.github.com) authenticated as a repo
admin, and it is safe to re-run. The `dependabot-automerge` workflow
additionally needs the repository's Allow auto-merge setting plus a
`DEPENDABOT_AUTOMERGE_TOKEN` secret (fine-grained PAT, contents + pull
requests write — a PAT so the merge still triggers workflows, which
`GITHUB_TOKEN` merges do not); until both exist it warns and does nothing.

## License

This project is licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) — see the
[LICENSE](LICENSE) file. Keep the [NOTICE](NOTICE) file's attribution with
any copies. It began as a modified version of
[filipdutescu's modern-cpp-template](https://github.com/filipdutescu/modern-cpp-template).
