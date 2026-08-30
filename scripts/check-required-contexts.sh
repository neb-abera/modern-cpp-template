#!/usr/bin/env bash
#
# check-required-contexts.sh — drift guard between the branch-protection
# contexts scripts/setup.sh requires and the job names the PR-triggered
# gate workflows actually produce. A renamed or added CI job that is not
# reflected in setup.sh silently stops gating merges on generated
# repositories; this check turns that drift into a red verify.sh run.
#
# Scope: ci.yml and security-scan.yml — the workflows whose jobs are merge
# gates. Deliberately excluded: codeql.yml (enforced by GitHub code
# scanning, not a status-check context), docs.yml (a build preview, not a
# gate), dependabot-automerge.yml (automation, produces no gate), the
# push/tag-only workflows (scorecard, release), and the scheduled-only
# fetchcontent-upgrade.yml (opens PRs, gates nothing).
#
# Exit codes: 0 = in sync, 1 = drift, 2 = python3/PyYAML unavailable (the
# caller may treat this as a skip; the toolchain container always has both).

set -euo pipefail
cd "$(dirname "$0")/.."

if ! python3 -c 'import yaml' 2> /dev/null; then
  echo "check-required-contexts: python3 with PyYAML is required (available in the toolchain container)" >&2
  exit 2
fi

python3 - <<'PY'
import re, sys, yaml

GATE_WORKFLOWS = [".github/workflows/ci.yml", ".github/workflows/security-scan.yml"]

# Job names of the gate workflows, with the one matrix pattern the template
# uses (${{ matrix.os }}) expanded from the job's own matrix definition.
expected = set()
for path in GATE_WORKFLOWS:
    with open(path) as f:
        wf = yaml.safe_load(f)
    for job_id, job in wf["jobs"].items():
        name = job.get("name", job_id)
        if "${{ matrix.os }}" in name:
            for os_value in job["strategy"]["matrix"]["os"]:
                expected.add(name.replace("${{ matrix.os }}", os_value))
        elif "${{" in name:
            sys.exit(f"unhandled matrix expression in job name: {name!r} ({path})")
        else:
            expected.add(name)

# The contexts setup.sh requires, parsed from its REQUIRED_CHECKS array.
with open("scripts/setup.sh") as f:
    setup = f.read()
m = re.search(r"REQUIRED_CHECKS=\(\n(.*?)\n\)", setup, re.DOTALL)
if not m:
    sys.exit("could not find the REQUIRED_CHECKS=( ... ) block in scripts/setup.sh")
required = set(re.findall(r'^\s*"([^"]+)"\s*$', m.group(1), re.MULTILINE))

missing = sorted(expected - required)   # jobs that exist but are not required
stale = sorted(required - expected)     # required contexts no job produces
for c in missing:
    print(f"DRIFT: gate job not in setup.sh REQUIRED_CHECKS: {c!r}")
for c in stale:
    print(f"DRIFT: required context with no matching gate job: {c!r}")
if missing or stale:
    sys.exit(1)
print(f"required contexts in sync: {len(required)} checks match the gate workflows' job names")
PY
