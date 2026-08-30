#!/usr/bin/env bash
#
# setup.sh — one-command setup for a repository generated from this template:
#
#   ./scripts/setup.sh
#
# What it does:
#   1. renames the project after your repository: the CMake project name and
#      option prefix, the *Config.cmake.in file, the presets and Makefile,
#      the include directory (and every #include of it), and the README
#      badge/links — then pushes the change
#   2. enables the GitHub security settings templates cannot carry over:
#      secret scanning, push protection, private vulnerability reporting,
#      Dependabot alerts and security updates
#   3. enables branch protection on the default branch requiring the gating
#      CI checks (the container jobs; the macOS/Windows portability smoke
#      legs are advisory and deliberately not required)
#
# Requirements: git, and the GitHub CLI (`gh`, https://cli.github.com)
# authenticated as an admin of the repository. Safe to re-run: every step is
# idempotent.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_PROJECT="Project"
TEMPLATE_OWNER_REPO="neb-abera/modern-cpp-template"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
done_() { printf '%s  done:%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s  note:%s %s\n' "$YELLOW" "$RESET" "$1"; }

#
# Detect the repository
#

origin=$(git remote get-url origin 2> /dev/null || true)
if [ -z "$origin" ]; then
  echo "error: no git remote named 'origin'. Clone your generated repository first." >&2
  exit 1
fi
owner_repo=$(printf '%s' "$origin" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
repo=${owner_repo##*/}

# CMake project name: the repository name sanitized to an identifier
name=$(printf '%s' "$repo" | sed -E 's/[^A-Za-z0-9_]/_/g; s/^([0-9])/_\1/')
name_lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

if ! command -v gh > /dev/null; then
  echo "error: the GitHub CLI (gh) is required — https://cli.github.com — and must be authenticated (gh auth login)." >&2
  exit 1
fi
default_branch=$(gh api "repos/$owner_repo" --jq .default_branch)

step "Setting up $owner_repo (project name: $name, default branch: $default_branch)"

#
# 1. Rename the project after the repository
#

if [ "$owner_repo" = "$TEMPLATE_OWNER_REPO" ]; then
  warn "this is the template itself; skipping the rename"
else
  step "Renaming project \"$TEMPLATE_PROJECT\" to \"$name\""

  NEW=$name perl -pi -e 's/\Q"Project"\E/"$ENV{NEW}"/' CMakeLists.txt
  # The workflows pass -D<name>_WARNINGS_AS_ERRORS=ON explicitly; without
  # renaming them too, a generated project's CI would set a dead variable
  # and silently lose warnings-as-errors.
  NEW=$name perl -pi -e 's/\QProject_\E/$ENV{NEW}_/g' CMakePresets.json Makefile \
    .github/workflows/ci.yml .github/workflows/release.yml

  if [ -f cmake/ProjectConfig.cmake.in ] && [ "$name" != "Project" ]; then
    git mv cmake/ProjectConfig.cmake.in "cmake/${name}Config.cmake.in"
  fi

  if [ -d include/project ] && [ "$name_lower" != "project" ]; then
    git mv include/project "include/$name_lower"
    NEW=$name_lower perl -pi -e 's#\Qinclude/project/\E#include/$ENV{NEW}/#g' cmake/SourcesAndHeaders.cmake
    NEW=$name_lower perl -pi -e 's#\Q"project/\E#"$ENV{NEW}/#g' src/*.cpp test/src/*.cpp
  fi

  NEW_REPO="$owner_repo" perl -pi -e 's#\Qneb-abera/modern-cpp-template\E#$ENV{NEW_REPO}#g' README.md
  NEW=$repo perl -pi -e 's/\QModern C++ Template\E/$ENV{NEW}/' README.md

  if git diff --quiet && git diff --cached --quiet; then
    done_ "already renamed"
  else
    git add -u
    git commit -q -m "Rename project after repository ($name) via scripts/setup.sh"
    if git push -q origin "HEAD:$default_branch" 2> /dev/null; then
      done_ "renamed and pushed to $default_branch"
    else
      warn "push to $default_branch was rejected (branch protection already on?); open a PR with the local commit"
    fi
  fi
fi

#
# 2. Repo security settings
#

step "Enabling security settings"
gh api -X PATCH "repos/$owner_repo" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  -f 'security_and_analysis[dependabot_security_updates][status]=enabled' > /dev/null
done_ "secret scanning, push protection, Dependabot security updates"
gh api -X PUT "repos/$owner_repo/private-vulnerability-reporting" > /dev/null
done_ "private vulnerability reporting"
gh api -X PUT "repos/$owner_repo/vulnerability-alerts" > /dev/null
done_ "Dependabot alerts"

#
# 3. Branch protection requiring the gating CI checks. Every required check
#    runs inside the project's toolchain container ("train as you fight");
#    the macOS/Windows portability smoke legs are advisory, so they are
#    deliberately absent from this list.
#

step "Enabling branch protection on $default_branch"
gh api -X PUT "repos/$owner_repo/branches/$default_branch/protection" --input - > /dev/null <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build & test (toolchain container)", "sanitizers (ASan + UBSan)", "thread sanitizer (TSan)", "coverage", "clang-format", "static analysis (clang-tidy)", "fuzz smoke (libFuzzer)"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
done_ "gating CI checks required, strict, enforced for admins"

#
# 4. GitHub Pages for the Doxygen docs (docs.yml deploys on pushes)
#

step "Enabling GitHub Pages (built by Actions)"
if gh api -X POST "repos/$owner_repo/pages" -f build_type=workflow > /dev/null 2>&1 \
   || gh api -X PUT "repos/$owner_repo/pages" -f build_type=workflow > /dev/null 2>&1; then
  done_ "Pages enabled; API docs deploy from docs.yml"
else
  warn "could not enable Pages automatically; enable it under Settings -> Pages -> Source: GitHub Actions"
fi

printf '\n%sSetup complete.%s Every future change now goes through a PR gated on the six
CI checks. Verify the renamed project with: make verify-docker\n' "$BOLD" "$RESET"
