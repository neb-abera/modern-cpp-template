---
name: Bug report
about: Report something that does not work as documented
title: "[BUG]"
labels: bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior, e.g. the preset/commands you ran:

```bash
cmake --preset release
cmake --build --preset release
ctest --preset release
```

**Expected behavior**
A clear and concise description of what you expected to happen.

**Actual behavior**
What happened instead — include the relevant output or error messages.

**Environment**

* OS: [e.g. Ubuntu 26.04, macOS 15, Windows 11]
* Compiler and version: [e.g. GCC 15, AppleClang 17, MSVC 19.4x]
* CMake version, or "toolchain container" if reproduced via `make verify-docker`

**Additional context**
Add any other context about the problem here.
