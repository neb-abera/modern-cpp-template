# Contributing

Thanks for your interest in improving this project. Bug reports, fixes and
focused improvements are all welcome.

## Development environment

Development is Docker-first: the repository ships a toolchain container
(see the [Dockerfile](Dockerfile)) with the exact compilers and tools CI
gates on, so the host only needs Docker and git.

```bash
make verify-docker   # the full verification suite, inside the container
make shell           # a development shell inside the same container
```

Working on the host directly also works if you have a recent CMake and
compiler; builds are driven by [CMake presets](CMakePresets.json):

```bash
cmake --preset release && cmake --build --preset release
ctest --preset release
```

`make help` lists the other targets (`test`, `coverage`, `asan`, `bench`,
`format`, `docs`, ...). The presets are `debug`, `release`, `coverage`,
`asan`, `tsan`, `tidy`, `bench` and `fuzz`.

## Before you open a pull request

Run the verification suite:

```bash
make verify-docker
```

It runs twelve checks: the release build with warnings-as-errors plus the
test suite, the same tests under ASan+UBSan and under TSan, clang-tidy,
fuzz and benchmark smoke runs, strict-standard-mode and executable-mode
checks, install-tree purity, a mutation canary, the required-contexts drift
guard, and clang-format. CI gates every pull request on the identical
suite, so a clean local run means green checks.

A few conventions:

* Write tests before or alongside the change; they should fail without it.
* One pull request per change; fill in the
  [pull request template](.github/PULL_REQUEST_TEMPLATE.md).
* Match the existing style — `make format` applies clang-format.
* Do not use `[skip ci]` / `[ci skip]`: the checks are required, so a
  commit that skips them cannot merge.

## Review and merging

Pull requests target the default branch, which is protected: all required
CI checks must pass, and the branch must be up to date. Reviews may take a
few iterations; small, well-described changes go fastest.

## Licensing

This project is licensed under the [Apache License 2.0](LICENSE). There is
no CLA: contributions are accepted under the inbound=outbound norm — by
submitting a pull request you agree that your contribution is licensed
under the project's license (Apache-2.0, section 5).

## Security issues

Do not open a public issue for a vulnerability. Use the private reporting
flow described in [SECURITY.md](SECURITY.md).
