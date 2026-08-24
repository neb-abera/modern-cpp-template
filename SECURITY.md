# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security updates.

## Reporting a Vulnerability

Please report vulnerabilities privately via
[GitHub's private vulnerability reporting](../../security/advisories/new)
rather than opening a public issue. You should receive a response within a
week. Please include a proof of concept or reproduction steps where possible.

## Hardening in this template

Projects generated from this template ship with:

* exploit-mitigation compiler/linker flags on by default
  (`<name>_ENABLE_HARDENING` in `cmake/StandardSettings.cmake`): stack
  protector, `_FORTIFY_SOURCE=3`, PIE, full RELRO and non-executable stack on
  Linux, Control Flow Guard and CET where available,
* an AddressSanitizer + UndefinedBehaviorSanitizer CI gate on every pull
  request,
* GitHub Actions and FetchContent dependencies pinned to full commit SHAs,
  kept current by Dependabot,
* least-privilege workflow tokens (`contents: read` except where releasing
  requires write),
* a non-root user in the development container.

## Known scanner findings (accepted)

CVE scans of the toolchain image (e.g. `trivy image modern-cpp-template:latest`)
report two classes of findings that are accepted deliberately:

* **`linux-libc-dev`**: kernel CVEs attributed to the kernel *headers*
  package. The headers are required to compile C++ on Linux and no kernel
  runs inside the container, so these do not apply to the build environment.
* **pip's vendored `msgpack`/`setuptools`** (inside the pipx shared venv):
  the latest pip still vendors these versions for its own internal use during
  installs. They are not importable by, or linked into, anything this project
  builds. Revisit when pip updates its vendored set.

The `conan` venv's own `setuptools`/`msgpack` are upgraded past known CVEs at
image build time, and the unused `pebble` service manager is removed from the
base image.
