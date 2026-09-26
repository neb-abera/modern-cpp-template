[![Actions Status](https://github.com/neb-abera/modern-cpp-template/workflows/CI/badge.svg)](https://github.com/neb-abera/modern-cpp-template/actions)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/neb-abera/modern-cpp-template/badge)](https://scorecard.dev/viewer/?uri=github.com/neb-abera/modern-cpp-template)
[![codecov](https://codecov.io/gh/neb-abera/modern-cpp-template/graph/badge.svg)](https://app.codecov.io/gh/neb-abera/modern-cpp-template)

# Modern C++ Template

A starting point for C++ projects: C++26 by default, CMake presets,
developed in Docker, gated by a test-driven verification suite, secured by
default.

## Features

* **Docker-first.** The host needs Docker and git. `make shell` opens a
  toolchain shell with GCC 16, Clang 23, CMake 4.2, clang-format,
  clang-tidy, Doxygen, ccache, Conan 2 and vcpkg, all pinned in the
  [`Dockerfile`](Dockerfile). `make verify-docker` runs the whole suite in a
  fresh container with the source mounted read-only.

* **Modern CMake.** C++26 by default, configurable through the
  `CXX_STANDARD` option. MSVC clamps to its newest mode until it ships one.
  Headers install through
  [file sets](https://cmake.org/cmake/help/latest/command/target_sources.html).
  Library, header-only and executable modes.
  [Presets](https://cmake.org/cmake/help/latest/manual/cmake-presets.7.html)
  (`debug`, `release` with LTO, `coverage`, `asan`, `tsan`, `tidy`, `bench`,
  `fuzz`, `vcpkg`), so building is `cmake --preset <name>` everywhere.

* **Test-driven.** GoogleTest (or Catch2 v3) fetched through `FetchContent`
  with a system-install fallback, cases registered with CTest through
  `gtest_discover_tests`, and a mutation canary that proves the tests catch
  a planted bug.

* **One verification suite.** `make verify` runs every check with a
  pass/fail tally: release build and tests (warnings as errors), ASan+UBSan,
  TSan, line coverage against the committed floor, clang-tidy, fuzz smoke,
  benchmark smoke, strict standard mode, executable smoke, install-tree
  purity (LICENSE and NOTICE included), the release size budget and its
  canary, the mutation canary, the CBMC proofs and the proof canary, a
  required-contexts drift guard, clang-format, the prose check, the
  attribution check, the `setup.sh` self-test and template parity. CI gates
  on the identical suite inside the toolchain container, plus macOS and Windows portability builds on native toolchains,
  warnings as errors on all three compilers. The list is at the top of
  [scripts/verify.sh](scripts/verify.sh).

* **A release size budget.** The stripped release artifact is measured in
  bytes against the committed [`size-budget.txt`](size-budget.txt), with a
  canary that proves the gate fails one byte over. Growth is a reviewed
  change to the budget.

* **Security.** OpenSSF compiler hardening and the C++26 hardened standard
  library on by default, CodeQL (C++ and workflows) on every PR, Actions
  pinned to commit SHAs, least-privilege tokens, harden-runner egress
  control and trivy image scanning. [SECURITY.md](SECURITY.md) has the
  inventory.

* **Prose is linted.** `make prose` runs Vale with the rules in
  `.vale/styles/Abera` over every Markdown file.

* **Kept current by Dependabot.** Every Action, the Docker base image and
  the linters (actionlint, shellcheck and Vale, stages of the `Dockerfile`)
  are pinned by commit SHA or digest with a version comment, and Dependabot
  bumps pin and comment together, minor and patch grouped into one weekly PR
  per ecosystem. The `dependabot-automerge` workflow arms auto-merge on
  every Dependabot PR, majors included. A bump that passes merges itself.
  One that breaks stays open and red. The FetchContent pins (googletest or
  Catch2, Google Benchmark) sit outside every Dependabot ecosystem, so the
  monthly `fetchcontent-upgrade` workflow moves them to the latest releases
  and opens the PR itself. The LLVM release tarball is outside them too, so
  the weekly `llvm-upgrade` workflow does the same for it.

* **Releases from tags.** Pushing `v*` builds and tests on all three
  platforms and publishes packaged install trees to a GitHub Release, with
  provenance attestations and SBOMs: one per shipped archive (its contents)
  and one of the toolchain container image (the build environment). Tag a
  working milestone to name a rollback point.

* **Ccache, Doxygen** (published to GitHub Pages on pushes to main) **and a
  devcontainer** for IDE setup.

## Getting started

Generate a repository from this template on GitHub, clone it, then:

```bash
make shell          # toolchain shell: edit on the host, build in the container
```

```bash
make verify-docker  # the full verification suite (what CI runs)
```

Inside the shell, or on a host with the prerequisites, building is presets
all the way down:

```bash
cmake --preset release && cmake --build --preset release && ctest --preset release
```

`make help` lists the rest (`test`, `coverage`, `asan`, `bench`, `docs`,
`format`, `lint`, `prose`).

Host builds and container builds must not share a `build/` directory. The
CMake cache records absolute compiler paths. `rm -rf build/` when switching
between the two.

### Prerequisites

* **Docker**, from [docker.com](https://www.docker.com/)
* **git**

Compilers and every analysis tool run inside the container. Developing on
the host instead needs CMake 3.28+ and GCC 14+ or Clang 17+, or MSVC. The
standard can be lowered to C++17, 20 or 23 through the
`<project_name>_CXX_STANDARD` option.

## Project layout

```
include/          public headers, installed via CMake file sets
src/              implementation and the optional executable entry point
test/             GoogleTest suite, registered per-case with CTest
bench/            Google Benchmark harness (`bench` preset)
fuzz/             libFuzzer harness built with ASan+UBSan (`fuzz` preset)
proof/            CBMC proof harnesses, checked by scripts/check-proofs.sh
cmake/            StandardSettings, CompilerWarnings, analyzers, install glue
scripts/          verify.sh / verify-docker.sh / setup.sh and the check-*.sh gates
.vale/            the writing rules (styles/Abera) and their self-test fixtures
Dockerfile        the pinned toolchain image CI and `make shell` share, and the prose linter stage
.github/          CI, CodeQL, Security scan, Docs and Release workflows (SHA-pinned), Dependabot
```

## Development workflow

1. Write a failing test in `test/`, or a fuzz or bench target when that
   layer owns the behavior.
2. `make shell` and implement until the test passes.
3. `make verify-docker` before pushing. CI gates on the identical suite.
4. When a milestone works, tag it (`git tag v1.2.0 && git push origin
   v1.2.0`) to publish a release ([SemVer](http://semver.org/)).

[CONTRIBUTING.md](CONTRIBUTING.md) has the pull-request process.

### Dependencies (package managers)

Both package managers use the `find_package` and `target_link_libraries`
flow in `CMakeLists.txt`.

* **vcpkg (manifest mode):** add dependencies to [`vcpkg.json`](vcpkg.json),
  point `VCPKG_ROOT` at a [vcpkg](https://github.com/microsoft/vcpkg)
  checkout, and configure with `cmake --preset vcpkg`.
* **Conan 2:** add dependencies to [`conanfile.txt`](conanfile.txt). The
  [cmake-conan](https://github.com/conan-io/cmake-conan) provider and the
  plain `conan install` flow are documented at the top of that file.

### Documentation

```bash
make docs     # Doxygen into docs/html; CI publishes it to GitHub Pages on main
```

## Where the practices come from

Each source below is wired to a failing check.

* **C++ Core Guidelines** (Stroustrup and Sutter, the successor to *C++
  Coding Standards*) and the **SEI CERT C++ standard.** clang-tidy's
  `cppcoreguidelines-*` and `cert-*` checks through the `tidy` preset, gated
  in CI, warnings as errors ([.clang-tidy](.clang-tidy)).
* **Effective (Modern) C++ and Effective STL** (Meyers). The `modernize-*`,
  `performance-*`, `readability-*` and `bugprone-*` checks in the same gate.
* **C++ Concurrency in Action** (Williams). The `tsan` preset runs the test
  suite under ThreadSanitizer in CI. The `concurrency-*` clang-tidy checks
  run statically.
* **cppbestpractices** (Jason Turner). The warning set in
  [CompilerWarnings.cmake](cmake/CompilerWarnings.cmake).
* **OpenSSF compiler hardening** and the **C++26 hardened standard
  library** (`_GLIBCXX_ASSERTIONS`, libc++ hardening). On by default in
  [StandardSettings.cmake](cmake/StandardSettings.cmake).
* **Memory errors and undefined behavior.** Address and UndefinedBehavior
  sanitizer runs on every PR.
* **Benchmarks.** A Google Benchmark harness ([bench/](bench/)) through the
  `bench` preset. A harness rather than a timing gate, because shared CI
  runners make numbers noise. CI proves it builds and runs.
* **Size budgets.** The stripped release artifact against a committed byte
  budget ([size-budget.txt](size-budget.txt)), the sibling of the web
  template's bundle budget. Bytes are deterministic on shared runners, so
  this one is a gate, and its canary proves it fails.
* **Proofs.** The harnesses in [proof/](proof/) are settled by
  [CBMC](https://github.com/diffblue/cbmc), a bounded model checker, on every
  pull request. Every other gate here is dynamic: the tests sample inputs, the
  sanitizers watch the sampled runs, the fuzzer searches for more. CBMC is the
  static one. It hands each property to a SAT solver and settles it for every
  input of the type, or returns a counterexample. `nondet_int()` is not a
  random value, it is an unconstrained one.

  `__CPROVER_assume` writes the precondition down. `tmp::add` takes two `int`
  and returns an `int`, so it cannot promise anything when the true sum does
  not fit, which is the same limitation [fuzz/](fuzz/)'s harness already
  documents. The proofs state that contract and then prove the function
  correct inside it, against a `long long` oracle, rather than suppressing the
  overflow check.

  The canary is the part that matters. A proof gate does not fail loudly, it
  reports success: an over-strong `__CPROVER_assume` proves a vacuous theorem
  and prints `VERIFICATION SUCCESSFUL`. So
  `scripts/check-proofs.sh --self-test` plants a wrong answer at one input the
  tests never sample, requires CBMC to fail on it, and requires it to pass
  again after the restore. Measured: 11 of 11 unit tests still pass with that
  bug in place, and CBMC catches it.

  CBMC carries its own SAT solver, so `CBMC_VERSION` is pinned in the
  Dockerfile and the gate fails when the installed version disagrees. A proof
  is only as good as the solver that checked it. cbmc comes from the Ubuntu
  archive, so on a Dependabot base image bump a workflow moves the pin to the
  new image's cbmc (`scripts/sync-cbmc.sh`) and the proofs run against it.

  The base image is the newest Ubuntu release, LTS or interim, or the
  development release once the suite is green on it. Today that is 26.10.
  `scripts/check-newest-ubuntu.sh`, run by `scripts/lint.sh`, fails when
  `.github/dependabot.yml` holds a release back, and when the image is 45
  days behind the newest release.

  The compilers are the newest releases too. Ubuntu 26.04 ships GCC 15 and
  LLVM 21. GCC 16 comes from the digest-pinned `gcc` image, which Dependabot
  bumps. LLVM comes from the release tarball, checked against its SHA-256.
  `scripts/check-newest-llvm.sh`, run by `scripts/lint.sh`, fails when a
  newer LLVM release has been out 30 days.

* **Fuzzing.** A libFuzzer harness ([fuzz/](fuzz/)) built with ASan+UBSan
  through the `fuzz` preset. CI smoke-runs it seeded from the committed
  regression corpus (`fuzz/corpus/<target>/`) and uploads any crash input
  as a CI artifact. A fixed crash gets its input committed to the corpus,
  so every later run replays it as a regression test. The harness is where
  a real project points the fuzzer at its parsers and input paths.

The web template's held-majors check has no counterpart here. It catches a
dependency major Dependabot stays silent about: an npm peer conflict or a
NuGet framework floor. CMake dependencies have no Dependabot ecosystem, so
there is no silent case to catch. What this template pins (the toolchain
image, the actions) Dependabot bumps loudly.

Naming, small functions and honest tests (*Code Complete*, *Clean Code*,
*Refactoring*) are what the mutation canary, the test-first workflow and
code review are for.

## After generating from this template

One command renames the project after your repository (CMake project name
and option prefix, the `*Config.cmake.in` file, presets, Makefile, the
include directory and every `#include` of it, and the README badges and
links, the Codecov coverage badge included) and enables the repository
settings templates cannot carry over: secret scanning, push protection,
private vulnerability reporting, Dependabot alerts and security updates,
GitHub Pages, Update branch, Allow auto-merge, and branch protection
requiring the gating CI checks. `./scripts/setup.sh --self-test` renames a
copy of the tree to `fake-widget`, fails on any template name left behind,
NOTICE included, and builds and tests the result. CI runs it on every pull
request.

```bash
./scripts/setup.sh
```

It needs the [GitHub CLI](https://cli.github.com) authenticated as a repo
admin, and it is safe to re-run. The `dependabot-automerge` workflow also
needs a `DEPENDABOT_AUTOMERGE_TOKEN` secret in the Dependabot namespace (a
fine-grained PAT with contents and pull-requests write, so the merge still
triggers workflows, which `GITHUB_TOKEN` merges do not). Until it exists
that job fails on every Dependabot pull request and nothing merges itself.
The coverage badge, rewritten to your repository by the same rename, reads
"unknown" until a `CODECOV_TOKEN` secret is added and coverage uploads once.

## License

[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). See
[LICENSE](LICENSE), and keep the [NOTICE](NOTICE) attribution with any
copies. It began as a modified version of
[filipdutescu's modern-cpp-template](https://github.com/filipdutescu/modern-cpp-template).
