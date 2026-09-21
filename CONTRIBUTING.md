# Contributing

Bug reports, fixes and focused improvements are welcome.

## Development environment

Development is Docker-first. The repository ships a toolchain container
(the [Dockerfile](Dockerfile)) with the compilers and tools CI gates on, so
the host needs Docker and git.

```bash
make verify-docker   # the full verification suite, inside the container
make shell           # a development shell inside the same container
```

Working on the host also works with a recent CMake and compiler. Builds are
driven by [CMake presets](CMakePresets.json):

```bash
cmake --preset release && cmake --build --preset release
ctest --preset release
```

`make help` lists the other targets (`test`, `coverage`, `asan`, `bench`,
`format`, `docs`, `prose`). The presets are `debug`, `release`, `coverage`,
`asan`, `tsan`, `tidy`, `bench` and `fuzz`.

## Before you open a pull request

Run the verification suite:

```bash
make verify-docker
```

It runs sixteen checks: the release build with warnings as errors plus the
test suite, the same tests under ASan+UBSan and under TSan, line coverage
against the floor in `coverage-floor.txt`, clang-tidy, fuzz and benchmark
smoke runs, strict-standard-mode and executable-mode checks, install-tree
purity, the release size budget and its canary, a mutation canary, the
required-contexts drift guard, clang-format, and the prose check. CI gates
every pull request on the identical suite, so a clean local run means green
checks. The prose check runs Vale through Docker, so inside the container
it skips. `make prose` runs it on the host, and CI's `prose` job runs it on
every pull request.

Conventions:

* Write tests before or alongside the change. They should fail without it.
* One pull request per change. Fill in the
  [pull request template](.github/PULL_REQUEST_TEMPLATE.md).
* Match the existing style. `make format` applies clang-format.
* Prose follows the writing rules in `.vale/styles/Abera`. `make prose`
  runs them over every Markdown file.
* Do not use `[skip ci]` or `[ci skip]`. The checks are required, so a
  commit that skips them cannot merge.

## Raising the size budget

The suite fails when the stripped release artifact outgrows the byte budget
committed in [size-budget.txt](size-budget.txt). If the growth is intended,
raise the budget in the same pull request as the change that needs it. Take
the measured size from the failing check's message (`make verify-docker`),
set the budget to about 20% above it, and say in the pull request what the
bytes bought. Never raise it to get to green.

## Review and merging

Pull requests target the default branch, which is protected. All required
CI checks must pass and the branch must be up to date. Small, well-described
changes go fastest.

## Licensing

This project is licensed under the [Apache License 2.0](LICENSE). There is
no CLA. By submitting a pull request you agree that your contribution is
licensed under the project's license (Apache-2.0, section 5), the
inbound=outbound norm.

## Security issues

Do not open a public issue for a vulnerability. Use the private reporting
flow described in [SECURITY.md](SECURITY.md).
