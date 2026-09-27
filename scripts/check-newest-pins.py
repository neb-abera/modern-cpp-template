#!/usr/bin/env python3
"""check-newest-pins.py: every GitHub release the Dockerfile pins is the newest.

Dependabot cannot see a release tarball, a .deb or a git commit. This covers
them: each pin is a pair of ENV lines in the Dockerfile, a version and its
integrity value (the asset's SHA-256, or for vcpkg the tag's commit).

  LLVM     llvm/llvm-project  LLVM-<v>-Linux-X64.tar.zst          LLVM_VERSION, LLVM_SHA256
  CBMC     diffblue/cbmc      ubuntu-24.04-cbmc-<v>-Linux.deb     CBMC_VERSION, CBMC_SHA256
  Doxygen  doxygen/doxygen    doxygen-<v>.linux.bin.tar.gz        DOXYGEN_VERSION, DOXYGEN_SHA256
  vcpkg    microsoft/vcpkg    (the tag's commit)                  VCPKG_VERSION, VCPKG_COMMIT

A release counts when it is neither a draft nor a prerelease and, where the
pin names an asset, ships it with a SHA-256 GitHub records.

  scripts/check-newest-pins.py              fail when a pin is behind a
                                            release out GRACE_DAYS (30)
  scripts/check-newest-pins.py --update     move every pin that is behind
  scripts/check-newest-pins.py --self-test  prove each check fails on a
                                            planted defect, for every pin

The pins-upgrade workflow runs --update weekly and opens the pull request.
Exit 1 on a finding. Exit 2 when a release listing cannot be read: an
outage, not a pass. GH_TOKEN, when set, lifts the API's anonymous limit.
"""
import json, os, re, shutil, sys, tempfile, time, urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRACE_DAYS = int(os.environ.get("GRACE_DAYS", "30"))

PINS = [
    {"name": "LLVM", "repo": "llvm/llvm-project", "tag": r"llvmorg-(\d+)\.(\d+)\.(\d+)",
     "asset": "LLVM-{v}-Linux-X64.tar.zst", "version": "LLVM_VERSION", "check": "LLVM_SHA256"},
    {"name": "CBMC", "repo": "diffblue/cbmc", "tag": r"cbmc-(\d+)\.(\d+)\.(\d+)",
     "asset": "ubuntu-24.04-cbmc-{v}-Linux.deb", "version": "CBMC_VERSION", "check": "CBMC_SHA256"},
    {"name": "Doxygen", "repo": "doxygen/doxygen", "tag": r"Release_(\d+)_(\d+)_(\d+)",
     "asset": "doxygen-{v}.linux.bin.tar.gz", "version": "DOXYGEN_VERSION", "check": "DOXYGEN_SHA256"},
    {"name": "vcpkg", "repo": "microsoft/vcpkg", "tag": r"(\d{4})\.(\d{2})\.(\d{2})",
     "asset": None, "version": "VCPKG_VERSION", "check": "VCPKG_COMMIT"},
]


class Outage(Exception):
    pass


def fetch(url):
    if url.startswith("file://"):
        try:
            with open(url[7:]) as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            raise Outage(f"could not read {url}: {e}")
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "check-newest-pins"})
    if os.environ.get("GH_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GH_TOKEN"])
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 - any failure to read is an outage
            last = e
            time.sleep(2 * (attempt + 1))
    raise Outage(f"could not read {url}: {last}")


def releases_url(pin):
    base = os.environ.get("RELEASES_BASE")
    if base:
        return f"{base}/{pin['name']}.json"
    return f"https://api.github.com/repos/{pin['repo']}/releases?per_page=50"


def commit_url(pin, tag):
    base = os.environ.get("RELEASES_BASE")
    if base:
        return f"{base}/{pin['name']}-commit-{tag}.json"
    return f"https://api.github.com/repos/{pin['repo']}/commits/{tag}"


def newest(pin):
    """(version, tag, published date, integrity value) of the newest release."""
    best = None
    for r in fetch(releases_url(pin)):
        m = re.fullmatch(pin["tag"], r.get("tag_name", ""))
        if not m or r.get("draft") or r.get("prerelease"):
            continue
        version = ".".join(m.groups())
        check = None
        if pin["asset"]:
            name = pin["asset"].format(v=version)
            asset = next((a for a in r.get("assets", []) if a.get("name") == name), None)
            if not asset or not str(asset.get("digest", "")).startswith("sha256:"):
                continue
            check = asset["digest"][len("sha256:"):]
        key = tuple(int(x) for x in m.groups())
        if best is None or key > best[0]:
            best = (key, version, r["tag_name"], r["published_at"][:10], check)
    if best is None:
        raise Outage(f"{pin['repo']} lists no release: an outage, not a pass")
    _, version, tag, date, check = best
    if check is None:
        check = fetch(commit_url(pin, tag)).get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", check):
            raise Outage(f"{pin['repo']}: no commit for {tag}: an outage, not a pass")
    return version, tag, date, check


def env(text, key):
    m = re.search(rf"^ENV {key}=(\S+)$", text, re.M)
    return m.group(1) if m else None


def dockerfile():
    return os.path.join(os.getcwd(), "Dockerfile")


def check():
    text = open(dockerfile()).read()
    status = 0
    for pin in PINS:
        cur, integrity = env(text, pin["version"]), env(text, pin["check"])
        if not cur or not integrity:
            print(f"error: the Dockerfile has no 'ENV {pin['version']}=' and 'ENV {pin['check']}=' pair", file=sys.stderr)
            status = 1
            continue
        version, _, date, _ = newest(pin)
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(date).replace(tzinfo=timezone.utc)).days
        if cur != version and age >= GRACE_DAYS:
            print(f"error: Dockerfile: {pin['name']} {cur} is behind {pin['name']} {version}, released {date}; "
                  "run scripts/check-newest-pins.py --update", file=sys.stderr)
            status = 1
        else:
            print(f"{pin['name']} {cur}: the newest release (or inside the {GRACE_DAYS}-day grace)")
    return status


def update():
    path = dockerfile()
    text = open(path).read()
    moved = []
    for pin in PINS:
        cur = env(text, pin["version"])
        version, _, date, integrity = newest(pin)
        if cur == version:
            print(f"{pin['name']} {cur} is the newest release")
            continue
        text = re.sub(rf"^ENV {pin['version']}=.*$", f"ENV {pin['version']}={version}", text, flags=re.M)
        text = re.sub(rf"^ENV {pin['check']}=.*$", f"ENV {pin['check']}={integrity}", text, flags=re.M)
        moved.append((pin, cur, version, date))
        print(f"{pin['name']} {cur} -> {version} (released {date})")
    open(path, "w").write(text)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"updates={'true' if moved else 'false'}\n")
    if os.environ.get("SUMMARY_FILE") and moved:
        with open(os.environ["SUMMARY_FILE"], "w") as f:
            for pin, cur, version, date in moved:
                f.write(f"- {pin['name']} {cur} to {version}, released {date}.\n")
            f.write("\nEach SHA-256 is the one GitHub records for the asset, and vcpkg's commit is its tag's. "
                    "CI builds the toolchain image, so a download that does not match fails the build.\n")
    return 0


def self_test():
    real = open(dockerfile()).read()
    failed = 0
    tmp = tempfile.mkdtemp()
    old = (datetime.now(timezone.utc).timestamp() - 200 * 86400)
    recent = (datetime.now(timezone.utc).timestamp() - 10 * 86400)
    iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT00:00:00Z")

    def tag_for(pin, version):
        parts = version.split(".")
        return {"LLVM": f"llvmorg-{version}", "CBMC": f"cbmc-{version}",
                "Doxygen": "Release_" + "_".join(parts), "vcpkg": version}[pin["name"]]

    def release(pin, version, when, pre=False, asset=True):
        assets = []
        if pin["asset"] and asset:
            assets = [{"name": pin["asset"].format(v=version), "digest": "sha256:" + "a" * 64}]
        return {"tag_name": tag_for(pin, version), "draft": False, "prerelease": pre,
                "published_at": iso(when), "assets": assets}

    def run(label, want, needle, fn, base, repo):
        nonlocal failed
        os.environ["RELEASES_BASE"] = "file://" + base
        cwd = os.getcwd()
        os.chdir(repo)
        import io, contextlib
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = fn()
        except Outage as e:
            code = 2
            err.write(str(e))
        finally:
            os.chdir(cwd)
            del os.environ["RELEASES_BASE"]
        text = out.getvalue() + err.getvalue()
        if code == want and needle in text:
            print(f"self-test: ok: {label} (exit {code})")
        else:
            print(f"self-test FAILED: {label}: wanted exit {want} and '{needle}', got exit {code}:\n    "
                  + text.replace("\n", "\n    "), file=sys.stderr)
            failed = 1

    for pin in PINS:
        cur = env(real, pin["version"])
        if not cur:
            print(f"self-test FAILED: no ENV {pin['version']}= in the Dockerfile to test against", file=sys.stderr)
            return 1
        parts = cur.split(".")
        nxt = f"{int(parts[0]) + 1}." + ".".join(parts[1:]) if pin["name"] == "vcpkg" else f"{int(parts[0]) + 1}.1.0"

        def fixtures(name, entries):
            d = os.path.join(tmp, name, pin["name"])
            os.makedirs(d, exist_ok=True)
            # Every other pin sees its own current release, so only this one can fail.
            for other in PINS:
                o = env(real, other["version"])
                rel = entries if other is pin else [release(other, o, old)]
                with open(os.path.join(d, f"{other['name']}.json"), "w") as f:
                    json.dump(rel, f)
                for r in rel:
                    with open(os.path.join(d, f"{other['name']}-commit-{r['tag_name']}.json"), "w") as f:
                        json.dump({"sha": "b" * 40}, f)
            return d

        repo = os.path.join(tmp, "repo-" + pin["name"])
        os.makedirs(repo)
        shutil.copy(dockerfile(), os.path.join(repo, "Dockerfile"))
        # The real pins must agree with their own fixture's integrity values for the check to pass.
        same = fixtures("same", [release(pin, cur, old)])
        behind = fixtures("behind", [release(pin, nxt, old), release(pin, cur, old)])
        grace = fixtures("grace", [release(pin, nxt, recent), release(pin, cur, old)])
        pre = fixtures("pre", [release(pin, nxt, old, pre=True), release(pin, cur, old)])
        empty = fixtures("empty", [])
        n = pin["name"]
        run(f"{n}: the real Dockerfile passes on the newest release", 0, "", check, same, repo)
        run(f"{n}: a release behind past the grace fails", 1, f"is behind {n} {nxt}", check, behind, repo)
        run(f"{n}: a release inside the grace passes", 0, "", check, grace, repo)
        run(f"{n}: a newer prerelease is not a release", 0, "", check, pre, repo)
        if pin["asset"]:
            noasset = fixtures("noasset", [release(pin, nxt, old, asset=False), release(pin, cur, old)])
            run(f"{n}: a newer release without the asset cannot be taken", 0, "", check, noasset, repo)
        run(f"{n}: a listing with no release is an outage", 2, "an outage, not a pass", check, empty, repo)
        run(f"{n}: --update moves the pin", 0, f"{n} {cur} -> {nxt}", update, behind, repo)
        moved = open(os.path.join(repo, "Dockerfile")).read()
        want = "b" * 40 if pin["name"] == "vcpkg" else "a" * 64
        if env(moved, pin["version"]) == nxt and env(moved, pin["check"]) == want:
            print(f"self-test: ok: {n}: the Dockerfile names {nxt} and its integrity value after --update")
        else:
            print(f"self-test FAILED: {n}: --update left {env(moved, pin['version'])} / {env(moved, pin['check'])}", file=sys.stderr)
            failed = 1
        run(f"{n}: the updated Dockerfile passes", 0, "", check, behind, repo)
        with open(os.path.join(repo, "Dockerfile"), "w") as f:
            f.write(re.sub(rf"^ENV {pin['check']}=.*\n", "", real, flags=re.M))
        run(f"{n}: a missing integrity pin fails", 1, f"no 'ENV {pin['version']}=' and 'ENV {pin['check']}=' pair", check, same, repo)
    shutil.rmtree(tmp)
    if not failed:
        print("self-test: every planted defect was caught, for every pin; the real Dockerfile passes")
    return failed


def main():
    os.chdir(ROOT)
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if mode == "--self-test":
            return self_test()
        if mode == "--update":
            return update()
        return check()
    except Outage as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
