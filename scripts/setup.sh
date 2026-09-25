#!/usr/bin/env bash
#
# setup.sh — one-command setup for a repository generated from this template:
#
#   ./scripts/setup.sh              set up the repository
#   ./scripts/setup.sh --self-test  prove the rename leaves no template name
#
# What it does:
#   1. renames the project after your repository: the CMake project name and
#      option prefix, the *Config.cmake.in file, the presets, Makefile and
#      workflows, the include directory (and every #include of it, in src/,
#      test/, bench/, fuzz/ and proof/), the repository links in README.md,
#      SECURITY.md and the issue-template contact link, and NOTICE. Then it
#      pushes the change
#   2. enables the GitHub settings templates cannot carry over: secret
#      scanning, push protection, private vulnerability reporting, Dependabot
#      alerts and security updates, delete-branch-on-merge, Update branch and
#      Allow auto-merge
#   3. enables branch protection on the default branch requiring the gating
#      CI checks (every job that runs on pull requests in ci.yml, codeql.yml
#      and security-scan.yml, the portability legs included)
#
# Requirements: git, perl, and the GitHub CLI (`gh`, https://cli.github.com)
# authenticated as an admin of the repository. Safe to re-run: every step is
# idempotent.
#
# --self-test copies the tracked tree into a temporary directory, gives it an
# origin named example-org/fake-widget and a stub `gh` that records its
# calls, and runs this script there. It then requires: no template name left
# in any tracked file (NOTICE included), the settings and required checks
# sent to GitHub, a second run that changes nothing, a planted leftover and a
# template NOTICE each caught by name, and the renamed project building and
# passing its tests.

set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE_PROJECT="Project"
TEMPLATE_REPO="modern-cpp-template"
TEMPLATE_OWNER_REPO="neb-abera/$TEMPLATE_REPO"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
done_() { printf '%s  done:%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s  note:%s %s\n' "$YELLOW" "$RESET" "$1"; }

# rename_project <owner/repo> <copyright holder>: rename the template in the
# current directory after the repository. Touches files and the git index
# only; the caller commits.
rename_project() {
  local owner_repo="$1" holder="$2" repo repo_lower name name_lower upstream
  repo=${owner_repo##*/}
  repo_lower=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  # CMake project name: the repository name sanitized to an identifier
  name=$(printf '%s' "$repo" | sed -E 's/[^A-Za-z0-9_]/_/g; s/^([0-9])/_\1/')
  name_lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

  NEW=$name perl -pi -e 's/\Q"Project"\E/"$ENV{NEW}"/' CMakeLists.txt
  # The workflows pass -D<name>_WARNINGS_AS_ERRORS=ON explicitly; without
  # renaming them too, a generated project's CI would set a dead variable
  # and silently lose warnings-as-errors.
  NEW=$name perl -pi -e 's/\QProject_\E/$ENV{NEW}_/g' CMakePresets.json Makefile \
    .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/codeql.yml

  if [ -f cmake/ProjectConfig.cmake.in ] && [ "$name" != "Project" ]; then
    git mv cmake/ProjectConfig.cmake.in "cmake/${name}Config.cmake.in"
  fi

  if [ -d include/project ] && [ "$name_lower" != "project" ]; then
    git mv include/project "include/$name_lower"
    NEW=$name_lower perl -pi -e 's#\Qinclude/project/\E#include/$ENV{NEW}/#g' cmake/SourcesAndHeaders.cmake
    NEW=$name_lower perl -pi -e 's#\Q"project/\E#"$ENV{NEW}/#g' \
      src/*.cpp test/src/*.cpp bench/*.cpp fuzz/*.cpp proof/*.cpp
  fi

  # Covers every owner/repo reference in these files, the README's CI and
  # Codecov badge URLs included, so a generated repository's badges point at
  # its own Actions runs and Codecov project (the coverage badge reads
  # "unknown" until a CODECOV_TOKEN secret is added and coverage uploads).
  NEW_REPO="$owner_repo" perl -pi -e 's#\Q'"$TEMPLATE_OWNER_REPO"'\E#$ENV{NEW_REPO}#g' \
    README.md SECURITY.md .github/ISSUE_TEMPLATE/config.yml
  # The image name the Makefile derives from the checkout directory.
  NEW=$repo_lower perl -pi -e 's#\Q'"$TEMPLATE_REPO"':latest\E#$ENV{NEW}:latest#g' SECURITY.md
  NEW=$repo perl -pi -e 's/\QModern C++ Template\E/$ENV{NEW}/' README.md

  # NOTICE names this project and its holder. Apache-2.0 section 4(d) asks a
  # derivative work to carry the template's attribution, so it follows,
  # below a blank line. Rewritten only while it is still the template's.
  if [ "$(head -1 NOTICE)" = "$TEMPLATE_REPO" ]; then
    upstream=$(sed -n 2p NOTICE)
    printf '%s\nCopyright %s %s\n\nThis project began from %s\n(https://github.com/%s).\n%s\nLicensed under the Apache License 2.0.\n' \
      "$repo" "$(date +%Y)" "$holder" "$TEMPLATE_REPO" "$TEMPLATE_OWNER_REPO" "$upstream" > NOTICE
  fi
}

# leftover_template_names <dir>: print every tracked line in <dir> that
# still names the template, and fail if there is one. Three places may name
# it on purpose: this script, the parity list (which names the web
# template), and the attribution the template owes: NOTICE below its first
# two lines, and the README's credit to the project the template began as.
leftover_template_names() (
  cd "$1"
  pattern='modern-cpp-template|Modern C\+\+ Template|neb-abera|Nebyou Abera|"Project"|(\b|-D)Project_|ProjectConfig|include/project\b|"project/'
  hits=$(git ls-files -z \
    | grep -zvxE 'scripts/setup\.sh|\.template-parity' \
    | xargs -0 grep -nE "$pattern" -- 2> /dev/null \
    | grep -vE '^README\.md:[0-9]+:.*filipdutescu/modern-cpp-template' \
    | grep -vE '^NOTICE:([3-9]|[1-9][0-9]+):' || true)
  if [ -n "$hits" ]; then
    echo "template names left behind:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    exit 1
  fi
  echo "no template name left in any tracked file"
)

#
# Self-test
#

SELF_TEST_FAILED=0
check() { # check <label> <command...>: record a pass or a failure
  local label="$1"; shift
  if "$@"; then
    echo "self-test: ok: $label"
  else
    echo "self-test FAILED: $label" >&2
    SELF_TEST_FAILED=1
  fi
}

self_test() {
  local dir log
  dir=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: the directory name is fixed
  trap "rm -rf '$dir'" EXIT
  log="$dir/setup.log"

  # The tracked tree, as a fresh repository whose origin is a GitHub name
  # that pushes to a local bare repository.
  mkdir -p "$dir/repo" "$dir/bin"
  # A worktree mounted into a container has a .git file pointing at a path
  # the container does not have, so without git the tree is copied whole.
  if git ls-files -z > "$dir/files" 2> /dev/null; then
    tar --null -T "$dir/files" -cf - | tar -xf - -C "$dir/repo"
  else
    tar --exclude=./.git --exclude=./build -cf - . | tar -xf - -C "$dir/repo"
  fi
  git init -q --bare "$dir/origin.git"
  (
    cd "$dir/repo"
    git init -q -b main
    git config user.name "Fake Widget Maintainer"
    git config user.email maintainer@example.invalid
    git config commit.gpgsign false
    git config core.hooksPath /dev/null
    git add -A
    git commit -qm "template"
    git remote add origin https://github.com/example-org/fake-widget.git
    git config url."$dir/origin.git".pushInsteadOf https://github.com/example-org/fake-widget.git
  )

  # A gh that records every call and its input, and answers the one
  # question the script asks.
  cat > "$dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'gh'; printf ' %s' "$@"; printf '\n'; cat; } >> "$GH_STUB_LOG"
case "$*" in *".default_branch"*) echo main ;; esac
STUB
  chmod +x "$dir/bin/gh"
  # shellcheck disable=SC2329 # invoked through check
  run_setup() {
    PATH="$dir/bin:$PATH" GH_STUB_LOG="$dir/gh.log" NO_COLOR=1 \
      bash "$dir/repo/scripts/setup.sh" < /dev/null >> "$log" 2>&1
  }

  check "setup.sh runs to the end against the fake repository" run_setup
  check "no template name is left in any tracked file" leftover_template_names "$dir/repo"
  check "NOTICE names the new project first" \
    test "$(head -1 "$dir/repo/NOTICE")" = "fake-widget"
  check "NOTICE names the new holder" \
    grep -qx "Copyright $(date +%Y) Fake Widget Maintainer" "$dir/repo/NOTICE"
  check "the rename was committed and pushed" \
    grep -q "Rename project after repository (fake_widget)" \
      <(git --git-dir="$dir/origin.git" log -1 --format=%s main)
  for want in allow_update_branch=true allow_auto_merge=true delete_branch_on_merge=true \
      '"strict": true' '"analyze (c-cpp)"' '"analyze (actions)"'; do
    check "gh was asked for $want" grep -qF -- "$want" "$dir/gh.log"
  done
  check "a second run changes nothing" run_setup
  check "the second run says so" grep -q "already renamed" "$log"

  # expect_leftover <dir> <text>: the scan must fail on <dir> and name <text>.
  # shellcheck disable=SC2329 # invoked through check
  expect_leftover() {
    local out
    if out=$(leftover_template_names "$1"); then return 1; fi
    printf '%s\n' "$out" | grep -qF -- "$2"
  }
  # Plant 1: a template name left in a tracked file.
  cp -R "$dir/repo" "$dir/planted"
  echo "See neb-abera/modern-cpp-template." >> "$dir/planted/README.md"
  check "a planted leftover fails the scan, by file" \
    expect_leftover "$dir/planted" "README.md:"
  # Plant 2: the template's own NOTICE, as a rename that skipped it leaves.
  cp -R "$dir/repo" "$dir/notice"
  git -C "$dir/repo" show HEAD~1:NOTICE > "$dir/notice/NOTICE"
  check "the template's NOTICE fails the scan, by file" \
    expect_leftover "$dir/notice" "NOTICE:1:modern-cpp-template"

  # The renamed project builds with warnings as errors and passes its tests.
  # shellcheck disable=SC2329 # invoked through check
  build_and_test() (
    cd "$dir/repo"
    if ! { cmake --preset release -Dfake_widget_WARNINGS_AS_ERRORS=ON \
        && cmake --build --preset release -j "$(getconf _NPROCESSORS_ONLN)" \
        && ctest --preset release; } > "$dir/build.log" 2>&1; then
      tail -30 "$dir/build.log" >&2
      exit 1
    fi
    grep -E 'tests passed' "$dir/build.log"
  )
  check "the renamed project builds and passes its tests" build_and_test

  if [ "$SELF_TEST_FAILED" -ne 0 ]; then
    echo "setup.sh output:" >&2
    sed 's/^/    /' "$log" >&2
    return 1
  fi
  echo "self-test: the rename left no template name, planted leftovers were caught by name, and fake-widget built and passed its tests"
}

case "${1:-}" in
  --self-test) self_test; exit ;;
esac

#
# Detect the repository
#

origin=$(git remote get-url origin 2> /dev/null || true)
if [ -z "$origin" ]; then
  echo "error: no git remote named 'origin'. Clone your generated repository first." >&2
  exit 1
fi
owner_repo=$(printf '%s' "$origin" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
name=$(printf '%s' "${owner_repo##*/}" | sed -E 's/[^A-Za-z0-9_]/_/g; s/^([0-9])/_\1/')

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
  holder=$(git config --get user.name || true)
  rename_project "$owner_repo" "${holder:-${owner_repo%%/*}}"

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
# Merged PR branches delete themselves; without this every merged PR leaves
# a dead branch behind, and the branch list turns to noise within a few
# dozen PRs.
# Update branch and Allow auto-merge: the protection below is strict, so a
# pull request behind the default branch cannot merge until it is updated.
# Without the button a Dependabot PR that falls behind never becomes
# mergeable, and without auto-merge dependabot-automerge.yml has nothing to
# arm.
gh api -X PATCH "repos/$owner_repo" \
  -F delete_branch_on_merge=true \
  -F allow_update_branch=true \
  -F allow_auto_merge=true > /dev/null
done_ "merged PR branches are deleted automatically; Update branch and auto-merge are on"

#
# 3. Branch protection requiring the gating CI checks: every job that runs
#    on pull requests in ci.yml, codeql.yml and security-scan.yml. The
#    container jobs are the "train as you fight" core; the macOS/Windows
#    portability legs gate too, so warnings-as-errors holds on all three
#    compilers. The list is .github/required-checks, and
#    scripts/check-required-contexts.sh fails when it and the workflows
#    disagree, so it runs first.
#

step "Enabling branch protection on $default_branch"
./scripts/check-required-contexts.sh > /dev/null
contexts=$(./scripts/check-required-contexts.sh --json)
gh api -X PUT "repos/$owner_repo/branches/$default_branch/protection" --input - > /dev/null <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": $contexts
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
# 4. Commit signing — require Verified commits, but only when this machine
#    can actually produce them, so a fresh adopter is never locked out of
#    their own default branch.
#

if [ "$(git config --get commit.gpgsign || true)" = "true" ]; then
  gh api -X POST "repos/$owner_repo/branches/$default_branch/protection/required_signatures" > /dev/null
  done_ "$default_branch accepts only Verified (signed) commits"
else
  warn "commit signing is not configured (commit.gpgsign is not true); $default_branch does NOT require signatures"
  warn "configure signing, then run: gh api -X POST repos/$owner_repo/branches/$default_branch/protection/required_signatures"
fi

#
# 5. Let workflows open pull requests. The monthly fetchcontent-upgrade
#    workflow proposes dependency-pin bumps as PRs; without this repository
#    setting its create-pull-request step fails. Default token permissions
#    stay read-only — workflows that need more grant it per job.
#

gh api -X PUT "repos/$owner_repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true > /dev/null
done_ "workflows may open PRs (fetchcontent-upgrade); default token stays read-only"

#
# 6. GitHub Pages for the Doxygen docs (docs.yml deploys on pushes)
#

step "Enabling GitHub Pages (built by Actions)"
if gh api -X POST "repos/$owner_repo/pages" -f build_type=workflow > /dev/null 2>&1 \
   || gh api -X PUT "repos/$owner_repo/pages" -f build_type=workflow > /dev/null 2>&1; then
  done_ "Pages enabled; API docs deploy from docs.yml"
else
  warn "could not enable Pages automatically; enable it under Settings -> Pages -> Source: GitHub Actions"
fi

printf '\n%sSetup complete.%s Every future change now goes through a PR gated on the
required CI checks in .github/required-checks. Verify the renamed project with: make verify-docker\n' \
  "$BOLD" "$RESET"
