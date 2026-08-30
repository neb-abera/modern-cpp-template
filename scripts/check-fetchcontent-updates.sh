#!/usr/bin/env bash
#
# check-fetchcontent-updates.sh — move the FetchContent dependency pins to
# their latest upstream releases. Dependabot has no FetchContent ecosystem,
# so the commit-SHA pins in test/CMakeLists.txt (googletest, Catch2) and
# bench/CMakeLists.txt (benchmark) would otherwise rot forever; the
# fetchcontent-upgrade workflow runs this monthly and opens a PR when
# anything moved.
#
# For each dependency: query the GitHub API for the latest release tag,
# resolve the tag to its commit SHA (tags are mutable, SHAs are not — the
# same reason the pins are SHAs), and when it differs from the current pin,
# rewrite the GIT_TAG line and the version comment above it in place.
#
# SUMMARY_FILE (optional): a markdown summary is written there, used as the
# PR body. GITHUB_OUTPUT (set by Actions): `updates=true|false` for the
# workflow to gate the PR step on. Requires `gh` authenticated (GH_TOKEN in
# CI). Exit 0 whether or not updates were found; non-zero only on errors.

set -euo pipefail
cd "$(dirname "$0")/.."

SUMMARY_FILE="${SUMMARY_FILE:-/dev/null}"

# name | owner/repo | CMakeLists that pins it
DEPS="
googletest|google/googletest|test/CMakeLists.txt
Catch2|catchorg/Catch2|test/CMakeLists.txt
benchmark|google/benchmark|bench/CMakeLists.txt
"

# The pinned SHA inside the FetchContent_Declare block for one repository:
# the first GIT_TAG after the block's GIT_REPOSITORY line.
current_pin() {
  local file="$1" repo="$2"
  awk -v repo="github.com/$repo" '
    $0 ~ repo { in_block = 1 }
    in_block && $1 == "GIT_TAG" { print $2; exit }
  ' "$file"
}

# Rewrite the block's GIT_TAG and its "# vX.Y.Z, pinned to its commit SHA"
# comment, keyed off the GIT_REPOSITORY line so same-file dependencies
# (googletest and Catch2) can never clobber each other.
rewrite_pin() {
  local file="$1" repo="$2" tag="$3" sha="$4"
  awk -v repo="github.com/$repo" -v tag="$tag" -v sha="$sha" '
    $0 ~ repo { in_block = 1 }
    in_block && /pinned to its commit SHA/ { sub(/# [^,]+,/, "# " tag ",") }
    in_block && $1 == "GIT_TAG" { sub(/GIT_TAG .*/, "GIT_TAG " sha); in_block = 0 }
    { print }
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

updates=false
{
  echo "Monthly FetchContent pin check (scripts/check-fetchcontent-updates.sh):"
  echo
} > "$SUMMARY_FILE"

while IFS='|' read -r name repo file; do
  [ -n "$name" ] || continue

  latest_tag=$(gh api "repos/$repo/releases/latest" --jq .tag_name)
  # commits/<tag> resolves annotated tags to the commit they point at.
  latest_sha=$(gh api "repos/$repo/commits/$latest_tag" --jq .sha)
  pinned_sha=$(current_pin "$file" "$repo")

  if [ -z "$pinned_sha" ]; then
    echo "error: no GIT_TAG pin found for $repo in $file" >&2
    exit 1
  fi

  if [ "$latest_sha" = "$pinned_sha" ]; then
    echo "$name: pinned at the latest release ($latest_tag), nothing to do"
    continue
  fi

  rewrite_pin "$file" "$repo" "$latest_tag" "$latest_sha"
  updates=true
  echo "$name: updated to $latest_tag ($latest_sha) in $file"
  echo "- **$name** ($repo): pin moved to $latest_tag (\`$latest_sha\`)" \
    "in \`$file\` — was \`$pinned_sha\`" >> "$SUMMARY_FILE"
done <<< "$DEPS"

if [ "$updates" = true ]; then
  {
    echo
    echo "Pins are commit SHAs because release tags are mutable; the version"
    echo "comment above each pin names the release the SHA belongs to."
    echo
    echo "PRs opened with the default workflow token do not trigger CI —"
    echo "close and reopen this PR (or push an empty commit) to run the checks."
  } >> "$SUMMARY_FILE"
else
  echo "All FetchContent pins are at their latest releases." >> "$SUMMARY_FILE"
fi

echo "updates=$updates" >> "${GITHUB_OUTPUT:-/dev/null}"
