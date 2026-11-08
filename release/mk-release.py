#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Assemble a P0.5 "audited release candidate" directory for one built ISO.

P0.5, item 1-3 and 5 from the project's own acceptance plan, in one script
rather than four separate ones, because they all read the same inputs (the
ISO's own manifest, the OBS project state, the local git repositories, the
.commit files mk-dsc.sh already records) and produce one coherent answer:
*where did every byte on this ISO actually come from, and is that knowable*.

Item 4 (install/upgrade/rollback/cloud-init/no-network/NIC-naming) is a
separate, already-closed acceptance pass -- see DEFECTS.md, "P0.5
install/upgrade/rollback acceptance: closed". This script's
verification-summary.json cites that result; it does not re-derive it.

What this produces, under <out>/<release-id>/:

    <iso-basename>.iso                copied in (or symlinked with --link)
    manifest.txt                      the ISO's own .packages file, verbatim
    manifest-vs-image.json            how the ISO's .packages manifest differs from
                                       what is really installed in the image
    sbom.json                         one row per package installed in the image: name,
                                       version, source package, where that
                                       source came from
    source-revision-map.json          the same resolution, keyed for lookup,
                                       with the five non-local_git categories
                                       from the acceptance plan and *why*
                                       each package landed in its category
    build-inputs.json                 OBS project _meta, build.dist, the
                                       local git HEAD of build-iso and
                                       toolkit, the obs-repo's own package
                                       count and content hash
    provenance.json                   per-package audit records: for Debian packages the
                                       .deb URL/sha256/size and the signed index that
                                       lists them, for local_git the published remote
                                       that contains the commit; plus what `verified`
                                       means per category
    verification-summary.json         PASS/FAIL/BLOCKED/NOT_APPLICABLE/
                                       NOT_RUN for every acceptance item this
                                       project tracks, not just the ones that
                                       happen to be green

Resolution categories (P0.5 item 3's split of "unknown"):

    local_git         installed version has a matching git commit recorded
                       by mk-dsc.sh at .dsc build time -- traceable to an
                       exact commit in an i-danos repository.
    local_git_version_stamped
                       same source package has exactly one recorded commit,
                       but under a *different* version string than what is
                       installed -- because the package's own debian/rules
                       overrides its version at build time (vyatta-version
                       does this deliberately, stamping the release number
                       via `dh_gencontrol -- -v$(VVERSION)` so the installed
                       package always carries "2608" regardless of what
                       debian/changelog says). Still traceable to an exact
                       commit; the version mismatch is by design, not a gap.
                       NEVER emitted at present: no available evidence links a commit to the
                       installed package,
                       so such cases are version_stamp_inferred.
    version_stamp_inferred
                       same shape as local_git_version_stamped (one recorded
                       commit under another version) but no evidence that the
                       build rewrites the version; the commit is a guess and
                       is marked verified=false.
    obs_package_revision
                       built by OBS (has a Source: entry in the repo's own
                       Packages index) but no matching .commit file for this
                       exact version -- e.g. rebuilt from a tag or a branch
                       tip mk-dsc.sh was not run against. Traceable to the
                       OBS package, not to a specific commit.
    signed_alias       version string is byte-identical to the 2105 baseline
                       manifest for the same package name -- inherited
                       unchanged from an official DANOS build rather than
                       rebuilt by this project at all.
    external_source    not built by this project's OBS project in any form;
                       came from the configured Debian mirror as-is.
    unresolved         none of the above matched. Always carries a reason,
                       per the acceptance plan's own rule: "禁止用 not_run
                       隐藏实际缺口" applies here too -- an unresolved entry
                       says why it could not be resolved, not just that it
                       wasn't.
"""

import argparse
import functools
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_OBS_DIR = Path("/home/aikon/danos/.obs")
DEFAULT_OBS_REPO = Path("/home/aikon/danos/build-iso/danos-build/obs-repo")
DEFAULT_BASELINE = Path(
    "/home/aikon/danos/build-iso/danos-sources/toolkit/docs/package-baselines"
    "/danos-2105.packages"
)
DEFAULT_SOURCES = Path("/home/aikon/danos/build-iso/danos-sources")
OBS_PROJECT = "home:i-danos"
OBS_API = "https://api.opensuse.org"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_repo_packages(packages_path):
    """obs-repo/Packages -> {binary_name: {"source": str, "version": str}}.

    dpkg-scanpackages omits Source: when it equals the binary package name --
    that omission is the signal, not a gap: it means source == binary here.
    """
    entries = {}
    name = version = source = None

    def flush():
        if name:
            entries[name] = {"source": source or name, "version": version}

    with open(packages_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line == "":
                flush()
                name = version = source = None
                continue
            if line.startswith("Package: "):
                flush()
                name = line[len("Package: "):].strip()
                version = source = None
            elif line.startswith("Version: "):
                version = line[len("Version: "):].strip()
            elif line.startswith("Source: "):
                # "Source: pkg (1.2-3)" form is possible; keep the name only.
                source = line[len("Source: "):].split(" ", 1)[0].strip()
        flush()
    return entries


def parse_iso_manifest(manifest_path):
    """The ISO's own <name>.packages file -> [(name, version)]."""
    out = []
    with open(manifest_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                out.append((parts[0], parts[1]))
    return out


def parse_dpkg_status(text):
    """var/lib/dpkg/status -> [{"name","version","arch","source"}] for installed packages.

    "source" is the Source: field's package name when present (dpkg omits it when
    the source has the binary's name), else the binary name.
    """
    out = []
    for blk in text.split("\n\n"):
        name = re.search(r"^Package: (\S+)", blk, re.M)
        status = re.search(r"^Status: (.*)", blk, re.M)
        version = re.search(r"^Version: (\S+)", blk, re.M)
        if name and version and status and "install ok installed" in status.group(1):
            arch = re.search(r"^Architecture: (\S+)", blk, re.M)
            src = re.search(r"^Source: (\S+)", blk, re.M)
            out.append({"name": name.group(1), "version": version.group(1),
                        "arch": arch.group(1) if arch else "",
                        "source": src.group(1) if src else name.group(1)})
    return out


def read_image(iso, workdir, apt_dir=None):
    """What is actually installed in the ISO -> [record], from its own dpkg status.

    The ISO's <name>.packages file is not that. It is written mid-build: on the
    2608 test ISO it lacked four installed packages (shim-signed,
    shim-signed-common, mokutil, grub-efi-amd64-signed -- exactly the signed-boot
    components an SBOM most needs to show) and listed two that the final image does
    not have, and it was byte-identical to the previous ISO's after a package list
    change. So the image's own /var/lib/dpkg/status, read out of the squashfs the ISO
    carries, is the source; the manifest is kept only to say how it differs.

    With apt_dir, the apt data the image itself carries -- /var/lib/apt/lists (the
    signed Debian InRelease files and Packages indexes it was installed from), the
    archive keys in /etc/apt/trusted.gpg.d and sources.list -- is extracted there
    too: it is the only place the .deb checksums of the Debian packages exist.
    """
    sq = Path(workdir) / "filesystem.squashfs"
    r = run(["xorriso", "-osirrox", "on", "-indev", str(iso), "-extract",
             "/live/filesystem.squashfs", str(sq)])
    if not sq.exists():
        sys.exit(f"could not extract /live/filesystem.squashfs from {iso}: {r.stderr[-300:]}")
    r = run(["unsquashfs", "-cat", str(sq), "var/lib/dpkg/status"])
    if apt_dir is not None:
        shutil.rmtree(apt_dir, ignore_errors=True)
        run(["unsquashfs", "-no-progress", "-f", "-d", str(apt_dir), str(sq),
             "var/lib/apt/lists", "etc/apt/trusted.gpg.d", "etc/apt/sources.list"])
    sq.unlink()
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"could not read var/lib/dpkg/status from the squashfs: {r.stderr[-300:]}")
    return parse_dpkg_status(r.stdout)


def installed_from_iso(iso, workdir):
    """read_image() reduced to [(name, version)]."""
    return [(r["name"], r["version"]) for r in read_image(iso, workdir)]


def parse_baseline(baseline_path):
    """toolkit/docs/package-baselines/danos-2105.packages -> {name: version}."""
    out = {}
    if not baseline_path.exists():
        return out
    with open(baseline_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split(None, 1)
            if len(parts) == 2:
                out[parts[0]] = parts[1].strip()
    return out


def index_commit_files(dsc_dir):
    """.obs/dsc/*.commit -> {(source, version_no_epoch): commit_sha}.

    mk-dsc.sh names these <src>_<ver-without-epoch>.commit, dropping any
    epoch because the same file can't be found under an epoch-qualified name
    later (see its own comment on this). Match on that stripped version.
    """
    out = {}
    for p in dsc_dir.glob("*.commit"):
        stem = p.stem  # <src>_<ver>
        if "_" not in stem:
            continue
        src, _, ver = stem.rpartition("_")
        out[(src, ver)] = p.read_text().strip()
    return out


def index_commits_by_source(commit_index):
    """{(source, version): sha} -> {source: {(version, sha), ...}}.

    Built from the same index resolve_source() matches exactly against, so a
    package whose *installed* version has no exact hit can still ask "does
    this source have exactly one commit recorded, just under some other
    version" -- the case a build-time version stamp (vyatta-version) creates
    on purpose, distinct from "no commit was ever recorded for this source".
    """
    out = {}
    for (src, ver), sha in commit_index.items():
        out.setdefault(src, set()).add((ver, sha))
    return out


# ---------------------------------------------------------------------------
# "verified": what it means, per category, and the records that back it.
#
# Until this existed no row was verified -- not even the local_git ones. The
# definitions are deliberately narrow; each says what it establishes and what it
# does not, and the same text is written into source-revision-map.json so an
# auditor does not have to read this file.
# ---------------------------------------------------------------------------

VERIFIED_DEFINITION = {
    "external_source": (
        "TRUE only if all of: (1) the installed name+version+architecture is an entry of a Debian "
        "Packages index that the image itself carries (/var/lib/apt/lists, the indexes it was "
        "installed from); (2) the signed InRelease for that suite verifies with gpgv against the "
        "Debian archive keys the image ships in /etc/apt/trusted.gpg.d; (3) the sha256 of the "
        "Packages file equals the one InRelease lists for it. Establishes: this exact "
        "package version is published by the Debian archive, with this .deb sha256 and size. "
        "Does NOT establish: that the bytes installed in the image are that .deb -- dpkg keeps no "
        "digest of the .deb, only per-file md5sums."
    ),
    "local_git": (
        "TRUE if EITHER (a) the recorded commit is an ancestor of a branch or tag tip that `git "
        "ls-remote` reports on the source repository's published remote (so it is in the public "
        "history, not just on a local branch), OR (b) the recorded commit is itself on no published "
        "tip but its tree (the complete source state) is byte-identical to the tree of a commit that "
        "IS reachable from such a tip -- the shape a history rewrite leaves, where the same content "
        "carries a new commit id; the reason string names that published commit. Establishes: the "
        "source content the installed package was built from exists in the published repository. "
        "Does NOT establish: that the recorded commit object itself is published (in case (b) it is "
        "not), nor that the installed .deb was built from it -- that link is the .commit file "
        "mk-dsc.sh wrote for this exact source version."
    ),
    "other": "always FALSE: version_stamp_inferred is a guess, obs_package_revision has no commit, "
             "signed_alias is inherited from the 2105 baseline unchanged, unresolved is unresolved.",
}


def parse_apt_packages(path):
    """A Debian Packages index -> {(name, version, arch): {...}} with only the fields provenance needs."""
    out = {}
    cur = {}

    def flush():
        if cur.get("Package") and cur.get("Version"):
            out.setdefault((cur["Package"], cur["Version"], cur.get("Architecture", "")), {
                "filename": cur.get("Filename", ""),
                "sha256": cur.get("SHA256", ""),
                "md5": cur.get("MD5sum", ""),
                "size": int(cur["Size"]) if cur.get("Size", "").isdigit() else None,
                "source": cur.get("Source", "").split(" ", 1)[0] or cur["Package"],
                "source_version": (re.search(r"\((.*?)\)", cur.get("Source", "")) or [None, None])[1]
                                  or cur["Version"],
            })

    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line == "\n":
                flush()
                cur = {}
                continue
            if line[0] in " \t":
                continue
            k, _, v = line.partition(":")
            if k in ("Package", "Version", "Architecture", "Filename", "Size", "SHA256", "MD5sum", "Source"):
                cur[k] = v.strip()
        flush()
    return out


def release_sha256_entries(inrelease_text):
    """InRelease -> {relative_path: sha256} from its SHA256: block."""
    out = {}
    in_block = False
    for line in inrelease_text.splitlines():
        if line.startswith("SHA256:"):
            in_block = True
            continue
        if in_block:
            if not line.startswith(" "):
                break
            parts = line.split()
            if len(parts) == 3:
                out[parts[2]] = parts[0]
    return out


def verify_inrelease(inrelease, keyring_dir):
    """gpgv-verify a clearsigned InRelease against the .asc/.gpg keys in keyring_dir -> (ok, detail)."""
    if not (shutil.which("gpgv") and shutil.which("gpg")):
        return False, "gpg/gpgv not installed on this host"
    keys = sorted(Path(keyring_dir).glob("*.asc")) + sorted(Path(keyring_dir).glob("*.gpg"))
    if not keys:
        return False, f"no archive keys in {keyring_dir}"
    with tempfile.TemporaryDirectory() as td:
        ring = Path(td) / "ring.gpg"
        with open(ring, "wb") as out:
            for k in keys:
                if k.suffix == ".asc":
                    r = subprocess.run(["gpg", "--batch", "--dearmor"], input=k.read_bytes(),
                                       capture_output=True)
                    out.write(r.stdout)
                else:
                    out.write(k.read_bytes())
        r = run(["gpgv", "--keyring", str(ring), "--status-fd", "1", str(inrelease)])
    good = re.search(r"^\[GNUPG:\] VALIDSIG (\S+)", r.stdout, re.M)
    if r.returncode == 0 and good:
        return True, f"gpgv VALIDSIG {good.group(1)}"
    bad = re.findall(r"^\[GNUPG:\] (BADSIG|NO_PUBKEY|EXPSIG|EXPKEYSIG|REVKEYSIG|ERRSIG) (\S+)", r.stdout, re.M)
    return False, "gpgv rejected the signature: " + (", ".join(" ".join(b) for b in bad) or r.stderr.strip()[-200:])


_LIST_NAME = re.compile(r"^(?P<host>[^_]+)_(?P<path>.+)_dists_(?P<suite>[^_]+)_(?P<rest>.+)$")


def load_apt_index(apt_dir, verifier=verify_inrelease):
    """The apt data read out of the image -> (index, releases).

    index:    {(name, version, arch): entry + suite/component/mirror/index_file/release_file}
    releases: {suite: {"inrelease","signature_ok","signature_detail","base_url","indexes":{file: bool}}}
    A Packages file counts as covered only if its sha256 is the one its InRelease lists.
    """
    lists = Path(apt_dir) / "var/lib/apt/lists"
    keys = Path(apt_dir) / "etc/apt/trusted.gpg.d"
    index, releases = {}, {}
    if not lists.is_dir():
        return index, releases
    for rel in sorted(lists.glob("*_InRelease")):
        m = _LIST_NAME.match(rel.name[:-len("_InRelease")] + "_x")
        if not m:
            continue
        host, path, suite = m.group("host"), m.group("path"), m.group("suite")
        prefix = rel.name[:-len("InRelease")]
        ok, detail = verifier(rel, keys)
        listed = release_sha256_entries(rel.read_text(errors="replace"))
        info = {"inrelease": rel.name, "signature_ok": ok, "signature_detail": detail,
                "base_url": f"http://{host}/{path}/", "indexes": {}}
        for pk in sorted(lists.glob(prefix + "*_Packages")):
            rest = pk.name[len(prefix):]                      # main_binary-amd64_Packages
            comp, _, tail = rest.partition("_binary-")
            arch = tail[:-len("_Packages")]
            want = listed.get(f"{comp}/binary-{arch}/Packages")
            matches = bool(want) and sha256_file(pk) == want
            info["indexes"][pk.name] = matches
            for key, ent in parse_apt_packages(pk).items():
                index.setdefault(key, {**ent, "suite": suite, "component": comp, "mirror": info["base_url"],
                                       "index_file": pk.name, "release_file": rel.name,
                                       "index_matches_release": matches})
        releases[suite] = info
    return index, releases


def debian_provenance(rec, index, releases):
    """One installed package -> (verified, reason, provenance dict) for an external_source row."""
    key = (rec["name"], rec["version"], rec["arch"])
    ent = index.get(key)
    prov = {"kind": "debian-archive", "distribution": "debian", "package": rec["name"],
            "version": rec["version"], "architecture": rec["arch"], "unavailable": {}}
    if ent is None:
        why = ("this name+version+architecture is not in any Packages index the image carries "
               f"({', '.join(sorted(releases)) or 'none'}): superseded since the image was assembled, "
               "or installed from a repository that is not Debian's")
        for f in ("deb_url", "deb_sha256", "deb_size", "suite", "component", "release_file"):
            prov["unavailable"][f] = why
        prov["conclusion"] = f"{rec['name']} {rec['version']} ({rec['arch']}): not found in the image's Debian indexes"
        return False, why, prov
    rl = releases.get(ent["suite"], {})
    sig_ok = bool(rl.get("signature_ok"))
    prov.update({
        "codename": ent["suite"].split("-")[0], "suite": ent["suite"], "component": ent["component"],
        "upstream_source_package": ent["source"], "upstream_source_version": ent["source_version"],
        "deb_url": ent["mirror"] + ent["filename"], "deb_sha256": ent["sha256"], "deb_size": ent["size"],
        "deb_md5sum": ent["md5"], "index_file": ent["index_file"], "release_file": ent["release_file"],
        "release_signature_ok": sig_ok, "release_signature_detail": rl.get("signature_detail", ""),
        "index_sha256_matches_release": ent["index_matches_release"],
    })
    for f in ("deb_sha256", "deb_size", "deb_md5sum"):
        if not prov[f]:
            prov["unavailable"][f] = "the index entry carries no such field"
    problems = []
    if not sig_ok:
        problems.append("InRelease signature not verified: " + rl.get("signature_detail", "unknown"))
    if not ent["index_matches_release"]:
        problems.append("the Packages file's sha256 is not the one InRelease lists")
    if not ent["sha256"]:
        problems.append("the index entry has no sha256")
    verified = not problems
    prov["conclusion"] = (
        f"Debian {ent['suite']}/{ent['component']} package {rec['name']} {rec['version']} ({rec['arch']}), "
        f"source {ent['source']}; .deb sha256 {ent['sha256'] or '(none)'} at {prov['deb_url']}; "
        + ("index covered by a gpgv-verified InRelease" if verified else "NOT verified: " + "; ".join(problems))
        + f". Not built by {OBS_PROJECT}."
    )
    return verified, ("; ".join(problems) if problems else "listed in the gpgv-verified Debian index"), prov


def source_dirs(sources_dir):
    """<sources>/*/debian/control -> {Source: package: directory}."""
    out = {}
    for ctl in sorted(Path(sources_dir).glob("*/debian/control")):
        try:
            m = re.search(r"^Source:\s*(\S+)", ctl.read_text(errors="replace"), re.M)
        except OSError:
            continue
        if m:
            out.setdefault(m.group(1), ctl.parent.parent)
    return out


DEFAULT_TAG_TIMEOUT = 900   # seconds allowed for each of the two tag passes (`git tag --contains`, `git for-each-ref refs/tags`)
DEFAULT_TAG_LIMIT = 200     # most tag tips the per-tip fallback / the unaligned-tag check will examine


def _ls_remote_reason(stderr):
    """git's complaint as one line: its fixed 'Please make sure ...' boilerplate dropped, the rest kept from the start
    (the old tail-160-characters cut the beginning off, e.g. 'om: Permission denied (publickey)')."""
    keep = [ln.strip() for ln in stderr.splitlines()
            if ln.strip() and not ln.startswith(("Please make sure", "and the repository exists"))]
    return " | ".join(keep)[:300]


def _tip_is_ancestor(repo, commit, sha):
    """True / False if `commit` is / is not an ancestor of `sha`; None if the clone does not have `sha` (cannot be read)."""
    if run(["git", "-C", repo, "cat-file", "-e", sha + "^{commit}"]).returncode != 0:
        return None
    return run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, sha]).returncode == 0


def check_commit_published(repo_dir, commit, ls_remote_cache, timeout=90,
                           tag_timeout=DEFAULT_TAG_TIMEOUT, tag_limit=DEFAULT_TAG_LIMIT):
    """Is `commit` in the published history of repo_dir's remote? -> (ok, detail, info).

    `git ls-remote --heads --tags` lists the tips; the commit counts only if it is an ancestor of one of
    them (and the tip itself is a commit this clone has, so the ancestry is read, not assumed).

    Cost: a repository can have thousands of tags (linux-vyatta: 4221), and asking `merge-base --is-ancestor` of every tip
    is one subprocess per tip -- an hour for a single commit that no tip contains. So, in order:
      1. the branch tips (a handful) are asked one by one, as before;
      2. the tags are asked in one pass: `git tag --contains <commit>` lists the local tags whose history
         holds the commit. That answer is only trusted for a tag whose local object equals the remote's (same name, same
         object id); tags the clone lacks or has at another object are checked tip by tip, at most `tag_limit` of them.
         A hit is re-verified with one `merge-base --is-ancestor` against the REMOTE tip, so the result never rests on
         for-each-ref alone;
      3. if for-each-ref fails or exceeds `tag_timeout`, the old tip-by-tip scan runs over at most `tag_limit` tags.
    A False that did not look at everything says how much it looked at ("checked N of M tag tips") and never claims
    "not an ancestor of any tip". The result per (repo, commit) is remembered in `ls_remote_cache`.
    """
    repo = str(repo_dir)
    key = ("published", repo, commit)
    if key in ls_remote_cache:
        ok, why, info = ls_remote_cache[key]
        return ok, why, dict(info)
    res = _check_commit_published(repo, commit, ls_remote_cache, timeout, tag_timeout, tag_limit)
    ls_remote_cache[key] = res
    return res[0], res[1], dict(res[2])


def _check_commit_published(repo, commit, ls_remote_cache, timeout, tag_timeout, tag_limit):
    info = {"repository": str(repo), "remote_url": None, "ref": None, "ref_tip": None}
    if run(["git", "-C", repo, "cat-file", "-e", commit + "^{commit}"]).returncode != 0:
        return False, "the commit is not in the local clone of the source repository", info
    remotes = []                      # (name, url) in preference order; the same URL under two names is tried once
    for name in ("i-danos", "origin"):
        r = run(["git", "-C", repo, "remote", "get-url", name])
        url = r.stdout.strip() if r.returncode == 0 else ""
        if url and url not in [u for _, u in remotes]:
            remotes.append((name, url))
    if not remotes:
        return False, "the source repository has no i-danos/origin remote", info
    # Ask `git ls-remote --heads --tags` of each remote in turn and use the first that answers: i-danos is the writable
    # one (ssh) and may be unusable where origin (https, anonymous read) still works. Only this query is used, never a fetch.
    # Every failure is kept so that "not reachable" can say which remotes were tried and why each failed.
    remote, tips, failures = None, None, []
    for name, url in remotes:
        if url not in ls_remote_cache:
            # `--heads` and `--tags` are asked SEPARATELY, heads first: a repository's branch tips are a handful of
            # refs, while its tags can number in the thousands and take minutes for the server to enumerate. Asking
            # both in one call let one slow tag listing hide every branch tip -- linux-vyatta (4226 tags) took over
            # 180 s, so packages whose commit sits on a branch were reported "remote not reachable". A tag timeout now
            # costs only the tag half, and the reason strings say the tag list is what went missing.
            got, why = [], []
            for flags, label in ((["--heads"], "branches"), (["--tags"], "tags")):
                try:
                    r = run(["git", "-C", repo, "ls-remote", *flags, url], timeout=timeout)
                    rows = [ln.split("\t") for ln in r.stdout.splitlines() if "\t" in ln]
                    if r.returncode == 0 and rows:
                        got.extend(rows)
                    elif r.returncode != 0:
                        why.append((label, _ls_remote_reason(r.stderr) or "no refs listed"))
                    else:
                        why.append((label, "no refs listed"))
                except subprocess.TimeoutExpired:
                    why.append((label, f"git ls-remote timed out after {timeout}s"))
            if got:
                if why:
                    ls_remote_cache[("tag-gap", url)] = why     # partial answer: said in the note of every verdict
                ls_remote_cache[url] = got
            else:
                # One dead remote must give one reason, not one per query: when both halves fail the same way, say it once.
                reasons = [r for _, r in why]
                ls_remote_cache[url] = (None, reasons[0]) if len(set(reasons)) == 1 else (None, "; ".join(f"{lab}: {r}" for lab, r in why))
        answer = ls_remote_cache[url]
        if isinstance(answer, tuple):
            failures.append(f"{name} ({url}): {answer[1] or 'no refs listed'}")
        else:
            remote, tips = url, answer
            break
    if remote is None:
        return False, "remote not reachable: " + "; ".join(failures), info
    info["remote_url"] = remote       # the URL actually used; the message below says "on <remote>" with the same value

    heads, tags = [], {}          # tags: ref -> {"obj": tag object id, "peeled": commit it points at}
    for sha, ref in tips:
        if ref.startswith("refs/tags/"):
            if ref.endswith("^{}"):
                tags.setdefault(ref[:-3], {})["peeled"] = sha
            else:
                tags.setdefault(ref, {})["obj"] = sha
        else:
            heads.append((sha, ref))
    missing = 0

    # 1. branch tips, the way it always was
    for sha, ref in sorted(heads, key=lambda t: (t[1] != "refs/heads/master", t[1] != "refs/heads/main", t[1])):
        r = _tip_is_ancestor(repo, commit, sha)
        if r is None:
            missing += 1
        elif r:
            info.update(ref=ref, ref_tip=sha)
            return True, f"ancestor of {ref} ({sha[:12]}) on {remote}", info

    names = sorted(tags)
    total = len(names)
    tip = lambda n: tags[n].get("obj") or tags[n].get("peeled")   # as ls-remote lists it (annotated tags peel inside git)
    seen = 0                                                      # tag tips whose ancestry was actually read
    stop = ""                                                     # why the tag check is not exhaustive, if it is not

    def hit(n):
        info.update(ref=n, ref_tip=tip(n))
        return True, f"ancestor of {n} ({tip(n)[:12]}) on {remote}", info

    # 2. tags in two cheap passes:
    #    `git tag --contains <commit>` -> short names of the local tags whose history holds the commit. It is used instead of
    #    `git for-each-ref --contains=<commit> refs/tags` because, measured on linux-vyatta (4221 tags), for-each-ref did not
    #    finish in 300 s while `git tag --contains` took 13 s: same question, different (much faster) implementation path.
    #    `git for-each-ref refs/tags` (no --contains) -> name -> object id of every local tag, to tell which tags sit at the
    #    object the remote lists, i.e. which tags the --contains answer may be trusted for.
    local, contains, failed = {}, set(), ""
    try:
        r = run(["git", "-C", repo, "tag", "--contains", commit], timeout=tag_timeout)
        if r.returncode != 0:
            failed = f"git tag --contains failed: {r.stderr.strip()[-120:] or r.returncode}"
        else:
            contains = {"refs/tags/" + ln.strip() for ln in r.stdout.splitlines() if ln.strip()}   # git tag prints short names
            r = run(["git", "-C", repo, "for-each-ref", "--format=%(refname)\t%(objectname)", "refs/tags"], timeout=tag_timeout)
            if r.returncode != 0:
                failed = f"git for-each-ref failed: {r.stderr.strip()[-120:] or r.returncode}"
            else:
                local = dict(ln.split("\t") for ln in r.stdout.splitlines() if "\t" in ln)
    except subprocess.TimeoutExpired:
        failed = f"git tag --contains / for-each-ref timed out after {tag_timeout}s"

    if not failed:
        aligned = {n for n in names if local.get(n) == tags[n].get("obj")}
        seen = len(aligned)       # `git tag --contains` answered for all of these at once
        cands = [n for n in names if n in aligned and n in contains]
        for n in cands[:tag_limit]:
            r = _tip_is_ancestor(repo, commit, tip(n))        # the one re-verification, against the remote's tip
            if r:
                return hit(n)
        if len(cands) > tag_limit:
            stop = f"limit {tag_limit} of {len(cands)} candidate tags re-verified"
        rest = [n for n in names if n not in aligned]          # no local tag at the remote's object: ask them one by one
        for n in rest[:tag_limit]:
            r = _tip_is_ancestor(repo, commit, tip(n))
            if r is None:
                missing += 1
            else:
                seen += 1
                if r:
                    return hit(n)
        if len(rest) > tag_limit:
            stop = (stop + "; " if stop else "") + f"limit {tag_limit} of {len(rest)} tags this clone lacks"
    else:
        # 3. the old tip-by-tip scan, capped
        for n in names[:tag_limit]:
            r = _tip_is_ancestor(repo, commit, tip(n))
            if r is None:
                missing += 1
            else:
                seen += 1
                if r:
                    return hit(n)
        if total > tag_limit:
            stop = f"limit {tag_limit}; {failed}"
        else:
            stop = ""
    notes = []
    if missing:
        notes.append(f"{missing} tips are not in the local clone, so they could not be checked")
    gap = ls_remote_cache.get(("tag-gap", remote))
    if gap:
        notes.append("the tags could not be listed (" + "; ".join(f"{lab}: {r}" for lab, r in gap) + "), so only the branch tips were examined")
    note = (" (" + "; ".join(notes) + ")") if notes else ""

    # 4. the same source content under a rewritten history. The build record names the commit `mk-dsc.sh` wrote
    #    at build time. If this project's history was later rewritten (authorship normalisation, rebase, a
    #    force-push), that commit object sits on no published tip while the tree it points at is byte-identical
    #    to a published commit's tree. A tree IS the whole source state, so "tree T is published as commit Y"
    #    answers the question this check asks -- is the source this package was built from in public history --
    #    without pretending the recorded commit object itself was published. Reported as its own reason, never
    #    as "ancestor of a tip", and the recorded commit stays untouched in the .commit file.
    published = [sha for sha, _ in heads] + [tip(n) for n in names]
    tree, same = _published_tree_match(repo, commit, published, ls_remote_cache)
    if tree and same:
        info.update(tree=tree, tree_identical_commit=same[0], tree_identical_count=len(same))
        more = f" (and {len(same) - 1} other published commit(s) carry the same tree)" if len(same) > 1 else ""
        return True, (f"the recorded commit is not itself published, but its tree {tree[:12]} is the tree of "
                      f"published commit {same[0][:12]} on {remote}{more}: the source content is in the public "
                      f"history, the commit object is not (history rewritten)"), info

    if stop:
        return False, (f"not found to be an ancestor of the tips examined: checked {seen} of {total} tag tips "
                       f"({stop}) and {len(heads)} branch tips" + note), info
    return False, (f"not an ancestor of any of the {len(heads) + total} remote branch/tag tips "
                   f"(checked {len(heads)} branch tips and {seen} of {total} tag tips)" + note), info


def _published_tree_match(repo, commit, published_tips, cache):
    """(tree of `commit`, the published commits whose tree is exactly that tree).

    "Published" means reachable from a tip `git ls-remote` listed AND present in this clone, so the answer is
    read from objects, never assumed from a ref name. One `git rev-list` + one `git log --all` per repository,
    remembered in `cache`; both are index scans, so the 1.2M-commit kernel history costs seconds, not hours.
    Returns (None, []) when the commit or every published tip is missing, or rev-list fails.
    """
    r = run(["git", "-C", repo, "rev-parse", commit + "^{tree}"])
    if r.returncode != 0:
        return None, []
    tree = r.stdout.strip()
    key = ("published-trees", repo)
    if key not in cache:
        have = [t for t in published_tips if t and run(["git", "-C", repo, "cat-file", "-e", t + "^{commit}"]).returncode == 0]
        by_tree = {}
        if have:
            q = run(["git", "-C", repo, "rev-list", *have], timeout=900)
            if q.returncode == 0:
                published = set(q.stdout.split())
                q = run(["git", "-C", repo, "log", "--all", "--format=%H %T"], timeout=900)
                if q.returncode == 0:
                    for line in q.stdout.splitlines():
                        parts = line.split()
                        if len(parts) == 2 and parts[0] in published:
                            by_tree.setdefault(parts[1], []).append(parts[0])
        cache[key] = by_tree
    return tree, sorted(cache[key].get(tree, []))


def enrich_rows(rows, records, index, releases, sources_dir=None, remote_check=True,
                checker=check_commit_published):
    """Add verified/verified_reason (every row) and provenance records (external_source, local_git).

    Categories and every existing field stay as they were, except external_source's one-sentence
    `reason`, which becomes the human-readable conclusion of its provenance record.
    Returns the provenance document's package list.
    """
    by_key = {}
    for r in records:
        by_key.setdefault((r["name"], r["version"]), r)
    dirs = source_dirs(sources_dir) if sources_dir else {}
    cache, prov_rows = {}, []
    for row in rows:
        cat = row["category"]
        rec = by_key.get((row["name"], row["version"]), {"name": row["name"], "version": row["version"], "arch": "", "source": row["name"]})
        if cat == "external_source":
            ok, why, prov = debian_provenance(rec, index, releases)
            row["reason"] = prov["conclusion"]
        elif cat == "local_git":
            d = dirs.get(row["source_package"])
            if not remote_check:
                ok, why, info = False, "remote check disabled (--no-remote-check)", {}
            elif d is None:
                ok, why, info = False, f"no directory under the sources root has `Source: {row['source_package']}`", {}
            else:
                ok, why, info = checker(d, row["commit"], cache)
            prov = {"kind": "local-git", "source_package": row["source_package"], "commit": row["commit"],
                    **info, "conclusion": f"{row['name']} {row['version']} from {row['source_package']} @ {row['commit'][:12]}: {why}"}
        else:
            ok = False
            why = row.get("reason", "") or f"{cat}: not verifiable"
            prov = None
        row["verified"] = bool(ok)
        row["verified_reason"] = why
        if prov is not None:
            prov_rows.append({"name": row["name"], "version": row["version"], "category": cat,
                              "verified": bool(ok), "verified_reason": why, "provenance": prov})
    return prov_rows


def verified_summary(rows):
    """Counts for the document header: true/false overall and by category, and why the false ones are false."""
    by_cat, reasons = {}, {}
    for r in rows:
        c = by_cat.setdefault(r["category"], {"true": 0, "false": 0})
        c["true" if r["verified"] else "false"] += 1
        if not r["verified"]:
            k = (r["category"], re.sub(r"\d+", "N", r["verified_reason"])[:140])
            reasons[k] = reasons.get(k, 0) + 1
    return {"true": sum(1 for r in rows if r["verified"]), "false": sum(1 for r in rows if not r["verified"]),
            "by_category": by_cat,
            "false_reasons": [{"category": c, "reason": w, "count": n}
                              for (c, w), n in sorted(reasons.items(), key=lambda kv: -kv[1])]}



def strip_epoch(version):
    return version.split(":", 1)[1] if ":" in version else version


# A static debian/rules override does not show that the older recorded commit
# produced the installed artifact. Until real build provenance (frozen source
# package hash, build log or attestation) is validated, nothing is confirmed.
# Sources whose rules are known to rewrite the version are only hinted.
VERSION_STAMP_RULES_HINT = {
    "vyatta-version": (
        "debian/rules override_dh_gencontrol: "
        "dh_gencontrol -p vyatta-version -- -v$(VVERSION)"
    ),
}


def resolve_source(name, version, repo_index, commit_index, baseline,
                    commits_by_source=None, provenance=None):
    """One installed (name, version) -> a source-revision-map entry."""
    repo_entry = repo_index.get(name)

    if repo_entry is not None and repo_entry["version"] == version:
        source = repo_entry["source"]
        ver_no_epoch = strip_epoch(version)
        commit = commit_index.get((source, ver_no_epoch))
        if commit:
            return {
                "category": "local_git",
                "source_package": source,
                "commit": commit,
            }
        # No .commit for *this* version -- but if the source has exactly one
        # recorded commit under some other version, the installed version was
        # very likely stamped at build time (debian/rules overriding it with
        # `dh_gencontrol -- -vX`), not actually untracked. Ambiguous (more
        # than one distinct commit on file) falls through to the honest
        # "no exact match" case below instead of guessing which one applies.
        alt = (commits_by_source or {}).get(source)
        if alt and len(alt) == 1:
            (alt_ver, alt_sha), = alt
            prov = (provenance or {}).get((name, version))
            claim = None
            if prov and prov["source_package"] == source and prov["commit"] == alt_sha \
                    and prov["source_version"] == alt_ver:
                # Corroborating, not proving: a trusted signer states this
                # commit and a buildinfo agrees on Source/Version/Binary. Neither
                # ties the commit to the built .deb, nor that .deb to the package
                # installed in the ISO (dpkg status carries no .deb digest), so
                # this never becomes verified.
                claim = {
                    "signed_by_trusted_key": True,
                    "buildinfo_file": prov["buildinfo_file"],
                    "buildinfo_sha256": prov["buildinfo_sha256"],
                    "unproven_links": [
                        "source commit -> built .deb (buildinfo records no commit)",
                        "built .deb -> package installed in the ISO (no .deb digest in the image)",
                    ],
                }
            # A single older commit is only a guess: nothing here shows that
            # debian/rules rewrote the version. Say so instead of confirming.
            return {
                "category": "version_stamp_inferred",
                "source_package": source,
                "commit": alt_sha,
                "verified": False,
                **({"provenance_claim": claim} if claim else {}),
                **({"provenance_rejected": "provenance present but does not name "
                    "this source and commit for the installed version"}
                   if (provenance or {}).get((name, version)) and not claim else {}),
                **({"rules_hint": VERSION_STAMP_RULES_HINT[source]}
                   if source in VERSION_STAMP_RULES_HINT else {}),
                "reason": (
                    f"installed as {version}; the only recorded commit for "
                    f"{source} is for version {alt_ver}. That this package's "
                    "build rewrites its version is not verified -- the commit "
                    "may not be the one that was built"
                ),
            }
        return {
            "category": "obs_package_revision",
            "source_package": source,
            "reason": (
                f"built by OBS project {OBS_PROJECT} ({source} {version}), "
                "no .commit file recorded for this exact version -- check "
                "whether mk-dsc.sh has been run since this was built, or "
                "whether it was built from a tag/branch tip outside that "
                "script's normal path"
            ),
        }

    if baseline.get(name) == version:
        return {
            "category": "signed_alias",
            "source_package": name,
            "reason": (
                f"version is byte-identical to the 2105 baseline manifest -- "
                "inherited unchanged, not rebuilt by this project"
            ),
        }

    if repo_entry is not None:
        # In this project's own repo index under a different version: it was
        # built here at some point, just not the version actually installed.
        return {
            "category": "unresolved",
            "source_package": repo_entry["source"],
            "reason": (
                f"OBS project {OBS_PROJECT} last built {repo_entry['source']} "
                f"{repo_entry['version']}, but {version} is what's installed "
                "-- local repo and obs-repo have drifted, or this came from "
                "a different repository entirely"
            ),
        }

    return {
        "category": "external_source",
        "source_package": name,
        "reason": "not built by this project's OBS project in any form",
    }


def obs_project_meta(obs_dir):
    osc = obs_dir / "osc"
    r = run([str(osc), "-A", OBS_API, "meta", "prj", OBS_PROJECT])
    if r.returncode != 0:
        return {"error": r.stderr.strip() or "osc meta prj failed"}
    return {"raw": r.stdout}


def git_head(repo_dir):
    r = run(["git", "-C", str(repo_dir), "rev-parse", "HEAD"])
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def git_dirty(repo_dir):
    r = run(["git", "-C", str(repo_dir), "status", "--short"])
    return bool(r.stdout.strip()) if r.returncode == 0 else None


def build_build_inputs(sources_dir, obs_repo_dir, obs_dir):
    build_iso = sources_dir / "build-iso"
    toolkit = sources_dir / "toolkit"
    build_dist = build_iso / "build.dist"

    packages_index = obs_repo_dir / "Packages"
    return {
        "obs_project": OBS_PROJECT,
        "obs_project_meta": obs_project_meta(obs_dir),
        "build_dist": (
            build_dist.read_text() if build_dist.exists() else None
        ),
        "build_iso_git_head": git_head(build_iso),
        "build_iso_git_dirty": git_dirty(build_iso),
        "toolkit_git_head": git_head(toolkit),
        "toolkit_git_dirty": git_dirty(toolkit),
        "obs_repo_package_count": sum(
            1 for _ in open(packages_index)
            if _.startswith("Package: ")
        ) if packages_index.exists() else None,
        "obs_repo_packages_sha256": (
            sha256_file(packages_index) if packages_index.exists() else None
        ),
    }


# --- verification-summary -------------------------------------------------
#
# Hand-maintained rather than scraped from DEFECTS.md, because the acceptance
# plan's own rule ("禁止用 not_run 隐藏实际缺口") requires every tracked item
# to appear even when it hasn't been run -- scraping a prose document for
# that would be more fragile than just listing what the plan itself lists.
# Update this table when an item's status actually changes; do not delete a
# NOT_RUN row to make the summary shorter.

VERIFICATION_ITEMS = [
    # P0.5 item 4 -- see DEFECTS.md, "P0.5 install/upgrade/rollback
    # acceptance: closed", for the evidence behind each PASS here.
    ("p0.5", "live_boot", "PASS", "verified repeatedly across this project's own regression runs"),
    ("p0.5", "disk_install_unattended", "PASS", "accept-disk-install.sh, cross-checked against the official 2105 ISO"),
    ("p0.5", "post_install_boot", "PASS", "confirmed via /proc/cmdline and vyatta-union after install"),
    ("p0.5", "reboot_persistence", "PASS", "config, admin account and ssh state survive a reboot"),
    ("p0.5", "upgrade_add_image", "PASS", "checksum fix (5.52) + grub write-path fix (5.53), both defect-tracked Re-run on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso with vm/accept-lifecycle.sh (13 of 13, see DEFECTS.md defect 23). Cross-version, measured: the disk installed from i-danos_2608_20260925T2005 (vyatta-image-tools 5.55) added i-danos_2608_20260926T0757 (5.57) over http, booted it (vyatta-image-tools 5.57 inside the running image), and rolled back to 5.55, with the admin account intact and dp0s3 unchanged (accept-lifecycle.sh with UPG_ISO, 12 of 12; evidence acceptance-2608-20260927/lifecycle-upgrade/)."),
    ("p0.5", "rollback", "PASS", "select original image, reboot, confirmed via /proc/cmdline Re-run on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso with vm/accept-lifecycle.sh (13 of 13, see DEFECTS.md defect 23)."),
    ("p0.5", "cloud_init", "PASS", "NoCloud seed hostname applied, no boot stall (defect 4's fix holds) Re-run on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso with vm/accept-lifecycle.sh (13 of 13, on a live boot with the cloud-init kernel token, since the installed disk boots without it by design; see DEFECTS.md defect 23)."),
    ("p0.5", "no_network_boot", "PASS", "zero -netdev, reached a usable login under a minute Re-run on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso with vm/accept-lifecycle.sh (13 of 13, started with -nic none, the guest has no network device; see DEFECTS.md defect 23)."),
    ("p0.5", "nic_naming_stability", "PASS", "dp0s3 name and MAC identical across a reboot Re-run on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso with vm/accept-lifecycle.sh (13 of 13, see DEFECTS.md defect 23)."),
    ("p0.5", "real_nic_hardware", "NOT_APPLICABLE", "deliberately out of scope for this pass; see UPGRADE-RECORD.md, 'What verified covers, and what it does not'"),
    # P0.5 items 1-3, 5 -- what this script itself produces.
    ("p0.5", "obs_project_revision_frozen", "PASS", "captured in build-inputs.json"),
    ("p0.5", "unified_release_directory", "PASS", "this directory"),
    ("p0.5", "sbom_generated", "PASS", "sbom.json, from the image's own dpkg status. Until 2026-09-24 it was built from the ISO's .packages manifest, which is a mid-build snapshot: it lacked shim-signed, shim-signed-common, mokutil and grub-efi-amd64-signed and listed libfribidi0 and shared-mime-info, which are not in the image (DEFECTS.md 20). manifest-vs-image.json records the difference for every release."),
    ("p0.5", "source_revision_map", "PASS", "source-revision-map.json, six-category split. Of the two obs_package_revision hits found on i-danos_2608_20260922T1655-amd64.hybrid-test.iso, vyatta-version turned out to have a recorded commit after all -- its debian/rules deliberately stamps the release number as the package version (dh_gencontrol -- -v$(VVERSION)), decoupled from debian/changelog's own '1.4' -- now correctly resolved as local_git_version_stamped. linux-signed is correctly obs_package_revision, not a gap -- its own Packages entry names 'Maintainer: OBS signing service <obssign@obs.service>', confirming it is the signed-kernel package OBS's signing infrastructure produces as a byproduct of building linux-image, with no source package of its own to check out."),
    ("p0.5", "results_normalized", "PASS", "this file"),
    # Robot regression (item key robot_81_cases, kept for compatibility), tracked
    # separately because it is per-ISO, not per-project -- re-run and re-record for
    # every release, not copied forward. vm/regression.sh now runs 8 suites / 99
    # cases; 81 is the 2026-09-26 value.
    ("regression", "robot_81_cases", "PASS", "8 suites / 99 cases (ipsec 10, mpls 11, dpa 8, evpn 9, fw 16, mcast 8, bgp 16, rest 21), the SUITES table of vm/regression.sh. The 81 cases quoted below are the historical value for i-danos_2608_20260926T0757-amd64.hybrid.iso and have been superseded by that 8-suite table; the item key robot_81_cases is kept because evidence and suite config pin it. Historical: 81/81 on the product image i-danos_2608_20260926T0757-amd64.hybrid.iso (vyatta-image-tools 5.57, vyatta-dataplane 3.14.42; MGMT_IF=dp0s31 MGMT_restore=dp0s31, IPSEC 10, MPLS 11, DPA 7, FIREWALL 16, BGP 16, REST 21, no case missing). Earlier per-ISO results, each on the ISO it names: 81/81 on the product image i-danos_2608_20260925T2005-amd64.hybrid.iso and on the test image i-danos_2608_20260925T1344-amd64.hybrid-test.iso (both built from one OBS repository, identical 1524-package sets), and 81/81 on i-danos_2608_20260922T1655-amd64.hybrid-test.iso, where an earlier run showed 27 unrelated failures traced to host CPU contention (~15 load average / 4 cores from concurrent unrelated VMs), not that build -- see DEFECTS.md. The test image was then rebuilt with 5.57 (i-danos_2608_20260926T0949-amd64.hybrid-test.iso): its 1524 installed packages are identical to the product image's, and it also passed 81/81 (tag t557). Re-run and update this row for every future release; do not copy this PASS forward to a different ISO."),
    # P1/P2 -- explicitly not started, per the project's own roadmap
    # ordering (P0.5 before P1 before P2). Listed so a reader of this summary
    # sees the whole plan, not just the part that is done.
    ("p1", "dpa_object_model_nexthop_group", "PASS", "nexthop-group class added to `dpa object show` (vyatta-dataplane 3.14.40, keyed inet|inet6/idx:N): enumerable on a live 3-router topology, and every nh_index that `route show` refers to appears in the enumeration on all three routers. State is no_support/sw-dataplane there because the VMs have no hardware backend, so the hardware-programmed case was not exercised. Not compared against zebra: there is no desired-side view of these groups, so it reports coverage but does not take part in drift detection."),
    ("p1", "dpa_object_model_interface_vlan", "PASS", "interface class added (vyatta-dataplane 3.14.41): records what creating each router interface returned. Verified live: a VLAN sub-interface (dp0s8.100) is enumerated as if:dp0s8.100, no_support/sw-dataplane, and is still there after a data plane restart. Physical DPDK ports are not listed because the data plane never asks the backend about them (hw_forwarding=0); see dpa_object_model_interface_routed_ports, which covers routed ports. Not compared against zebra."),
    ("p1", "dpa_object_model_interface_routed_ports", "PASS", "vyatta-dataplane 3.14.42 lists routed ports in the interface class as not_needed/sw-dataplane instead of leaving them out, so a port the data plane never asked the backend about can be told from an interface that does not exist. Verified live on the installed i-danos_2608_20260926T0757-amd64.hybrid.iso (3.14.42): with nothing configured dp0s3 (the management port, dhcp) and dp0s4 are both listed not_needed; after dp0s4 gets an address and a VLAN sub-interface dp0s4.100 the class shows if:dp0s3 not_needed, if:dp0s4 not_needed, if:dp0s4.100 no_support; the same three after systemctl restart vyatta-dataplane. Every listed name is an interface the guest really has (dp0s3 dp0s4 dp0s4.100). lo, pimreg and pim6reg are not listed, and that is by construction: only three interface types define ifop_l3_enable (dpdk-eth, gre, vlan), so only they ever ask the backend for a router interface, and the enumerator lists only interfaces whose type has that op (read from vyatta-dataplane src/if.c and the ift_ops tables; loopback and pimreg define none). The same rule leaves out bridge, vxlan, macvlan, vti, l2tpeth, ppp, ipip and vrf interfaces. Run for a bridge SVI on the installed product image: br0 with an address is not listed whether it is down (no member) or up with a live member, and lo with an added address is not listed either (evidence acceptance-2608-20260927/dpa-bridge/). vxlan, macvlan, vti, l2tpeth, ppp, ipip and vrf are read from the code, not run. Not compared against zebra. Evidence: acceptance-2608-20260926/dpa-interface/."),
    # Split on 2026-11-05 on the operator's instruction: one row that said nothing
    # measurable was replaced by three, one per class family. The old note's claim
    # that "the two QoS classes are still not_enumerable" was wrong -- see the qos
    # row -- so the split also removes a factual error, without touching any other
    # item's status.
    ("p1", "dpa_object_model_qos", "PASS", "qos-if and qos-vlan are enumerable on this product: after a `policy qos` is committed, `dpa object show qos-if` and `dpa object show qos-vlan` return rc=0 and one object each -- qos-if:dp0s4 and qos-vlan:dp0s4/100, both state full, backend sw-dataplane -- and toolkit/vm/judge-dpa-object-model-extension.py with --require qos-if,qos-vlan exits 0. Raw capture: acceptance-p05/dpa-r1/raw/11-qos-if-configured.txt, 12-qos-vlan-configured.txt, 13-full-configured.json on ISO sha256 61ec76d13d3d43ec544f41b8d1a6f8f9ff749fa0c43bb6410546658b06340eb7. That capture has not yet been registered as a signed, artifact-bound case, so until it is this row reads NOT_RUN; the earlier note's 'still not_enumerable' was a factual error, not a stale status. Not compared against zebra: zebra carries no QoS state, so this is coverage only and takes no part in drift detection."),
    ("p1", "dpa_object_model_tunnel", "NOT_RUN", "no tunnel class exists in the product: dpa_classes[] (src/dpa_object.c:40-52) holds 10 classes and neither tunnel nor GRE is among them, so `dpa object show tunnel` exits 1 while printing a valid empty document -- an unknown class is indistinguishable from an empty one by body alone. GRE interfaces are real (src/if/gre.c, 2801 lines) and appear in the interface class as if:tun0 no_support/sw-dataplane, but the FAL layer keeps only an opaque tun handle with no per-object state, so a tunnel class needs new state recording first. Read from source plus a live `dpa object show`; the GRE data path itself was not exercised."),
    ("p1", "dpa_object_model_acl", "NOT_RUN", "no ACL class exists in dpa_object, and the firewall side is not ready to back one: `npf-op show` can list attach points and rule groups (F1, rule 10), but src/npf records no PD_OBJ_STATE and the hardware ACL table is never created in this software-only image, so there is nothing to enumerate. Would need a defined object identity before a class can be added."),
    ("p1", "drift_state_machine", "PASS", "implemented in dpa-drift.py --watch: all eight named states (observed, transient_in_flight, reserved_owned, source_mismatch, next_hop_dependency, unsupported_or_unreadable, stale_candidate, confirmed_stale), promotion arithmetic unit-tested deterministically, classification verified live against a real router."),
    ("p1", "comparison_scope_route6", "PASS", "COMPARED in dpa-drift.py now includes route6 alongside route; desired()/programmed() parameterized by object class, keys carry (class, vrf, prefix). Verified live against r1: single-snapshot and --watch both ran clean, route6's reserved objects (::/0, ::1/128, etc.) correctly classified reserved_owned, and a genuine route6 disagreement (fe80::/64) tracked correctly through the watch-mode streak. Also found live, not assumed: route6's DPA state string is lowercase where route's is upper -- classify_extra now normalizes case, or route6's own unsupported objects would have misclassified as source_mismatch."),
    ("p1", "comparison_scope_mpls_route", "PASS", "COMPARED in dpa-drift.py now includes mpls-route, keyed by incoming label (zebra 'show mpls table json' vs DPA 'lblspc:0/label:N'). Verified live on the TOPO=fw three-router L3VPN scenario (verify-l3vpn.sh: OSPF+LDP+VPNv4, label 144, cross-VRF ping 5/5): every zebra-installed label (R1 16/17/144, R2 16/17, R3 likewise) matched, no false drift; DPA's reserved labels 0/1/2 are excluded as owned=unknown. Detection also verified: with brokerd paused on R2 and a new loopback added on R1, label:21 (and 9.9.9.9/32) went missing -> stale_candidate at streak 3 -> confirmed_stale at streak 6 -> gone after brokerd resumed (induce-drift-mpls.sh). MPLS label delivery goes through brokerd."),
    ("p1", "comparison_scope_mcast", "PASS", "COMPARED in dpa-drift.py now includes mroute and mroute6, keyed (source,group) per VRF from 'show ip[v6] mroute vrf all json' against DPA 'vrf:X/(S,G)'. Verified live on the TOPO=fw SSM/IPv6 scenario (verify-multicast-forwarding.sh, 5000 packets each way): R2's (65.1.1.2,232.1.1.1), (2001:db8:65::2,ff0e::1) and (::,ff0e::1) all matched, including zebra's '*' -> '::' any-source mapping, no false drift. Detection also verified: pausing brokerd did NOT create multicast drift (the (S,G) reached the data plane anyway -- multicast does not go through brokerd), but pausing vplaned did: a new (65.1.1.2,232.1.1.3) went missing -> stale_candidate -> confirmed_stale at streak 6 -> resolved on resume (induce-drift-mcast.sh). The IPv4 any-source mapping is now observed, not assumed: zebra '*' <-> DPA '(0.0.0.0,239.1.1.1)', matched with a static RP and an any-source join."),
    ("p1", "drift_detection_induced", "PASS", "the state machine detects real, induced drift in three classes, not just the absence of false positives: pausing a delivery process on R2 (SIGSTOP/SIGCONT, no test hook, no FPM bounce) produced observed -> stale_candidate (streak 3) -> confirmed_stale (streak 6) -> resolved for a static route (198.51.100.0/24, brokerd paused), an mroute (vplaned paused) and an mpls-route (brokerd paused). Scripts: induce-drift-{route,mcast,mpls}.sh. Not done: route6 and a *extra* (programmed-not-desired) drift were not induced."),
    ("p1", "drift_event_correlation_config_commits", "PASS", "dpa-drift-correlate.py correlates dpa-drift-history.py's events against configd's own commit log (journalctl -u configd, 'COMMIT: Commit OVERALL' lines, microsecond timestamps) within a configurable window, adding correlated_commit/gap_seconds or a reason when nothing qualifies. Verified live against r1 both directions: a real confirmed_stale event (fe80::/64, reached that state organically this run) correctly resolved to no correlated commit; a synthetic event 1.3s after a real commit correctly resolved to it. Also verified on a real induced route drift on the same router: gap 0.208s. Limitation found: it reads only the LOCAL configd log, so a drift on R2 caused by a commit on R3 or R1 (multicast join, new loopback) correctly finds nothing on R2 but cannot see the real cause."),
    ("p1", "drift_event_correlation_netlink", "PASS", "dpa-drift-correlate-netlink.py correlates events against vyatta-dataplane's netlink route log ('ROUTE: RTM_NEWROUTE/RTM_DELROUTE ... dst <prefix> ...'), which turned out to already exist -- gated behind the dataplane's nl_route debug category, off by default ({\"0x13\":[\"init\",\"link\",\"nl_interface\"]}), toggleable at runtime with no restart (vplsh -c 'debug nl_route' / 'debug -nl_route', both directions confirmed live). Correlates by prefix only, not (vrf, prefix) -- the log line carries a table number, not a VRF name -- stated as a limitation. Verified live against r1: a synthetic event just after a real RTM_DELROUTE correctly correlated (gap_seconds 0.254); an untouched prefix correctly resolved to null; on a real induced drift with brokerd paused it correctly found nothing (the data plane never saw the route). Limitation: unicast RTM_*ROUTE only -- multicast (S,G) and MPLS label events are never matched."),
    ("p1", "drift_event_correlation_broker_dp_transactions", "NOT_RUN", "brokerd->dataplane *delivery* is already covered by the netlink row: vyatta-dataplane's route_broker.c receives brokerd's ZMQ route messages and feeds them through the same rtnl_process() that emits the 'ROUTE: RTM_*ROUTE' line (source read, and consistent with the live capture, where a route committed via zebra/FPM/brokerd logged exactly that line). What remains NOT_RUN is *completion* -- the FAL/DPA programming result after delivery -- for which the only failure log found is DP_DEBUG(ROUTE, NOTICE) 'route message not handled' on a parse failure; no success/completion log has been located, and brokerd's own journal is empty past startup"),
    ("p2", "power_loss_recovery_config_commit", "PASS", "verify-power-loss.sh on a freshly installed 2608 disk: qemu SIGKILLed at 23 judged moments during 'commit; save' of 40 static routes (the operation that rewrites /config/config.boot), then booted again from the same disk. 23 of 23 came back to ssh with a writable filesystem, no failed units, exactly the complete old (15) or complete new (8) config.boot by hash, and file and running routes in agreement; 0 partial or corrupt. A 10-point sweep across the measured 2.02s commit+save window flipped from old to new between 1.91s and 2.01s with nothing in between. Scope limits: SIGKILL is a power cut as the guest sees it, not a host power failure (host page cache survives, so a hypervisor that ignores flushes is not tested); only config commit+save was cut, not boot or image upgrade; one transition sample, not a dense scan. Harness errors found and fixed on the way are in DEFECTS.md."),
    ("p2", "power_loss_recovery_boot", "PASS", "verify-power-loss-more.sh MODE=boot: qemu SIGKILLed 4, 8, 12, 16, 20, 25, 30, 40 and 50 seconds after start (firmware, kernel, initramfs, overlay mount, systemd), then booted again. 9 of 9 came back to ssh with a writable filesystem, no failed units, the identical config.boot and a complete image set. Same guest-visible-power-cut limit as the commit case."),
    ("p2", "power_loss_recovery_upgrade", "PASS", "verify-power-loss-more.sh MODE=upgrade. The first sweep (cuts at fractions of the install time) found 2 unrecoverable states in 13: grub.cfg naming the new image as default while its data was not on disk (GRUB 'file /boot/upg1/vmlinuz not found' at 'Press any key', or 'Can not mount ... .squashfs' at an (initramfs) shell). Root cause: install_image() had no sync before the grub.cfg update (DEFECTS.md 16); fixed in vyatta-image-tools 5.54 and shipped in 5.55. Verified with an event-triggered A/B: cut at +0, 0.5, 1, 2, 4, 6s after grub.cfg first changes. Old installer (5.53) as upgrade source: 4 passed, 2 failed (+0.5s and +1s: default = new image, squashfs truncated) -- the positive control, so the method hits the window. New installer (5.55, in ISO i-danos_2608_20260924T1022): 6 passed, 0 failed. Limits: one trial per offset per installer; guest-visible power cut, not a host power failure; the journal-replay hypothesis for the masked 24.7s case is untested."),
    ("p2", "power_loss_recovery_real_host_and_first_boot", "NOT_RUN", "no real host power loss or disk-cache-ignoring hypervisor was tested, and no cut was placed during the FIRST boot of a newly installed image (a leftover disk from a killed first boot refused the vyatta login; not examined)"),
    ("p2", "signed_boot_chain_live_iso", "PASS", "verify-secure-boot.sh with real OVMF (Secure Boot on, Microsoft keys). The ISO's chain is Debian shim 16.1 (Microsoft-signed) -> GRUB and kernel signed with the OBS project's own self-signed certificate (valid to 2028-10-29). T1 Microsoft keys only: refused by shim ('Verification failed: (0x1A) Security Violation'). T2 OBS certificate enrolled as MOK: boots, kernel logs 'UEFI Secure Boot is enabled', lockdown initialized. T3 one bit flipped in GRUB: refused by shim. T4 one bit flipped in the kernel: GRUB reaches its menu then 'bad shim signature'. T2 vs T4 differ by one bit. Deployment requirement: the OBS certificate must be enrolled as a MOK; without it the ISO does not boot under Secure Boot."),
    ("p2", "signed_boot_chain_installed_disk", "PASS", "the rebuilt ISO (vyatta-image-tools 5.55 + shim-signed) installed to a blank disk under OVMF Secure Boot: install image ran to 'Setting up grub on /dev/vda: OK' (the old ISO died on the missing linuxefi.mod, defect 17). The installed ESP holds shimx64.efi (Microsoft-signed), grubx64.efi (OBS certificate), mmx64.efi and fbx64.efi (Debian CA), BOOTX64.CSV, grub.cfg (defect 18: the old package set wrote no shim). Booted alone with the installer's NVRAM: entry 'Vyatta-vda' -> shim -> GRUB 2.12 -> Vyatta 2608 menu -> node login:. One bit flipped in the installed grubx64.efi (qemu-io on a disk copy): shim stops at 'Verification failed: (0x1A) Security Violation'. Limits: one tamper location; the MOK was written into NVRAM, not enrolled through MokManager."),
    ("p2", "signed_boot_chain_kernel_view_and_add_image_check", "PASS", "observed on the installed UEFI system under Secure Boot, with root and a network (needed the IOMMU setup, see secure_boot_dataplane_requires_iommu). Kernel's own view: 'mokutil --sb-state' = SecureBoot enabled, the kernel logs 'Secure boot enabled', /sys/kernel/security/lockdown = [none] (this kernel is LOCK_DOWN_KERNEL_FORCE_NONE, Secure Boot does not lock it down). add system image <URL>: after the download and MD5 check the installer prints 'Signing check, no match in signature list for .../shimx64.efi.signed' and 'Continue with installation? (Yes/No) [No]'. Cause, shown with the certificates: check_binary_signatures compares the signer SUBJECT of each binary with the SUBJECTS in the firmware db; the shim's signer subject is '...CN=Microsoft Windows UEFI Driver Publisher' while db holds its issuer 'Microsoft Corporation UEFI CA 2011', so it never matches, and the function returns at the first miss. GRUB and kernel (OBS certificate, trusted via MOK, not in db) would also miss; the check never consults the MOK. So on a standard Secure Boot machine add system image always warned and defaulted to No, even with the certificate enrolled: a false alarm to override, not a functional break. Fixed since: see add_system_image_signing_check."),
    ("p2", "add_system_image_signing_check", "PASS", "check_binary_signatures fixed in two steps, vyatta-image-tools 5.56 (code af89a40, version edd2628) and 5.57 (f87e9c1): the whole signing chain is compared with db, not just the signer, which makes the Microsoft-signed shim match on its issuer 'Microsoft Corporation UEFI CA 2011'. 5.56 alone was not enough -- on an installed system under OVMF Secure Boot the check then failed at GRUB, whose OBS certificate is a MOK and not in db. 5.57 also trusts the MOK list (mokutil --export) for GRUB and the kernel, while shim stays db-only. Measured on the installed disk of i-danos_2608_20260926T0757-amd64.hybrid.iso with the real binaries: the shipped function returns success; the same code with MOK support disabled fails at GRUB, so the pass is the MOK and not a check that cannot fail. NOT covered: the interactive 'add system image <URL>' run end to end (it needs an ISO to add and a network path into a Secure Boot guest, which the data plane's IOMMU requirement makes awkward), and a machine whose db or MOK is different from the one tested."),
    ("p2", "secure_boot_dataplane_requires_iommu", "PASS", "on the q35 UEFI machine with Secure Boot on the data plane did not start and the NIC stayed enp0s2. Cause read from the service's own output and the source: vplane-uio prints 'Secure Level / Lockdown enabled and iommu/vfio not available' and exits 255, by design -- with no IOMMU and Secure Boot on (dmesg contains 'Secure boot enabled') it refuses uio_pci_generic. Verified both ways on the same disk and NVRAM: with a virtual IOMMU (q35 kernel-irqchip=split, intel-iommu, NIC iommu_platform=on) the data plane is active, the NIC is bound to vfio-pci and is dp0p0s2 with a DHCP address; with Secure Boot off it starts on uio_pci_generic. NIC name on q35 is dp0p0s2 (dp<F>p<N>s<S>), not dp0s2. A deployment requirement: a Secure Boot machine needs an IOMMU for the DANOS data plane. A first explanation (kernel lockdown) was wrong: on the real Secure Boot machine lockdown is [none]. Not tested on real hardware with VT-d."),
    ("p2", "signed_boot_chain_mok_enrollment_flow", "PASS", "the operator's real MOK enrollment, walked through with a screenshot per step (mok-import.sh + MokManager driven by key presses): mokutil --import on the installed system with Secure Boot supported but off, Secure Boot on, reboot -> shim starts MokManager -> Enroll MOK -> View key 0 (issuer/subject CN=home:i-danos OBS Project, Code Signing, SHA-1 fingerprint and serial matching openssl byte for byte) -> Enroll the key(s)? (defaults to No) -> Password -> Reboot -> shim -> GRUB -> login. In the guest: SecureBoot enabled, mokutil --list-enrolled shows the OBS certificate beside the Debian Secure Boot CA. Operator gotchas reproduced and documented in DEFECTS.md: mokutil needs Secure Boot-capable firmware; 'mokutil --import' silently skips this certificate (Already in kernel trusted keyring, exit 0) unless --ignore-keyring is given; the request is consumed even if nothing is enrolled (a Shift key gets no key event, MokManager times out); the menu opens on Continue boot."),
    ("p2", "signed_boot_chain_sbat_revocation", "PASS", "same ISO and NVRAM (OBS certificate enrolled). The ISO's GRUB declares grub,5; shim's SbatLevel is grub,5: GRUB menu in ~24s. With SbatLevel grub,6 (virt-fw-vars --set-sbat-level) shim logs 'component grub, generation 5, was revoked by SbatLevel variable' and 'Verification failed: Security Policy Violation'; no GRUB menu. Consequence: this GRUB is exactly at the current revocation level, so when the minimum grub generation is raised to 6 the image stops booting under Secure Boot until GRUB is rebuilt and re-signed from a newer Debian grub2; nothing in the image or the release process tracks that."),
    ("p2", "signed_boot_chain_certificate_expiry", "PASS", "VM clock set to 2030-01-01 (guest date confirms), past the OBS certificate's 2028-10-29 end: shim -> GRUB -> kernel still boot, kernel logs 'Secure boot enabled', login prompt. shim does not check validity dates, so an expired signing certificate does not stop an existing image from booting. Only the boot chain was tested, not a build signed after expiry or kernel module loading."),
    ("p2", "signed_boot_chain_dbx", "NOT_RUN", "a firmware dbx entry revoking the shim's signer or hash was not tested: it is the firmware's own behaviour, not specific to this image. The SBAT test covers the revocation shim and GRUB enforce."),
    ("p2", "physical_nic_dpdk_binding", "PASS", "i-danos_2608_20260927T0704-amd64.hybrid.iso (vyatta-dataplane 3.14.42, vyatta-image-tools 5.57) installed on a BayTrail box with a physical 4-port Intel I210 (net_e1000_igb). All four ports run, one at a time (a single test cable moved between them): each brought up at a-1g/a-full with a static address, vyatta-dataplane/frr/configd active, systemctl --failed empty, ping 0% loss both directions, ssh works, and show interfaces dataplane <if> counters show non-zero 1/5/15-minute rx/tx tracking the traffic sent -- identical result on dp0p1s0 through dp0p4s0, packets moved through the data plane on real hardware, not virtio. Gigabit copper, light traffic only, never more than one port carrying traffic at once: multi-queue/RSS, aggregate/simultaneous throughput, VLAN/bonding on a physical port, link flap/NIC reset, offloads and power-loss recovery on this hardware are not covered. See DEFECTS.md, 'Real hardware: 2608 boots, and its data plane forwards, on a physical I210 NIC'."),
    # A02 phase 3 (component compensation on commit failure), checked on a booted guest.
    # These rows leave NOT_RUN only through a signed evidence record whose raw result
    # is the JUnit file toolkit/vm/verify-case.py writes for the case of the same
    # name under toolkit/vm/cases/, and only with the operator's suite config
    # (--suite-config; verify-case.py --emit-suite-config writes the entry).
    # What exists today was observed by hand and is not bound to an artifact.
    ("a02", "a02_f6_rule_without_action", "NOT_RUN", "rules without an action and a notification rule without a name commit, read back and reconcile clean on the booted image (A02 stage 3-H). Observed once by hand on i-danos_2608_20261026T0452-amd64.hybrid.iso (handoff/verify/R3-f6-20261026.md); no artifact-bound result yet. Evidence: the JUnit of toolkit/vm/cases/f6.yaml run against a real guest"),
    ("a02", "a02_item12_w2_journal_write_failure", "NOT_RUN", "the end-of-commit journal write (W2) fails and the failure is reported to the operator instead of passing silently (A02 item 12). Captured once by hand on i-danos_2608_20261026T0452-amd64.hybrid.iso with a fault injector (handoff/verify/R3-item12-20261026.md); no artifact-bound result yet. Evidence: the JUnit of toolkit/vm/cases/item12.yaml run against a real guest"),
    ("a02", "a02_p2p4_seam_crash_journal", "NOT_RUN", "crash points P2 (dispatch record durable, call not sent) and P4 (component replied, record not yet settled) on the booted image, via the default-off hooks in configd 2.12.2danos6. The seams were hit and the journal state recorded by hand (handoff/verify/R3-p2p4-capture-20261026.md); the fence and reconcile verdicts after the crash were not reached, and P4 cannot yet be told from P3 with certainty. Evidence: the JUnit of toolkit/vm/cases/p2p4.yaml run against a real guest"),
]


# Everything in VERIFICATION_ITEMS marked PASS other than the rows this script
# produces is a *historical* result recorded for particular images. Nothing here
# binds a result to an artifact (ISO SHA256, suite commit, raw result hash), and
# an image name is not an identity: a rebuilt ISO can reuse a name. So no
# measured row is ever reported as current; the recorded result is kept as
# "historical" next to a NOT_RUN status.
SCRIPT_OUTPUT_ROWS = {
    "obs_project_revision_frozen", "unified_release_directory",
    "sbom_generated", "source_revision_map", "results_normalized",
}
HISTORICAL_OVERRIDES = {
    "i-danos_2608_20260926T0949-amd64.hybrid-test.iso": {
        "robot_81_cases": (
            "PASS",
            "Historical 81/81 (the 2026-09-26 suite table; vm/regression.sh now has 8 suites / 99 cases) on this test image (tag t557; IPSEC 10, MPLS 11, DPA 7, FIREWALL 16, BGP 16, "
            "REST 21, no case missing), vyatta-image-tools 5.57, vyatta-dataplane 3.14.42. Its "
            "installed package set (1524) is identical to the product image "
            + "i-danos_2608_20260926T0757-amd64.hybrid.iso" + "'s, built from the same OBS repository. Not carried over from "
            "another image.",
        ),
        "disk_install_unattended": (
            "PASS",
            "accept-disk-install.sh, 14 of 14 on this test image, installed disk booted and restarted, "
            "data plane active afterwards.",
        ),
    },
}
HISTORICAL_IMAGE_NOTES = {
    "i-danos_2608_20260926T0757-amd64.hybrid.iso":
        "product image the rows above were recorded against",
    "i-danos_2608_20260926T0949-amd64.hybrid-test.iso":
        "test image with its own robot_81_cases and disk_install_unattended results",
}


def sha256_of(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
EVIDENCE_FORMAT = "danos-verification-evidence-v2"
PROVENANCE_FORMAT = "danos-build-provenance-v2"


TRUSTED_KEYS_FILE = Path(__file__).resolve().with_name("trusted-keys.sha256")


def pinned_key_problem(key_path):
    """(ok, reason): key_path is one of the release roots listed in trusted-keys.sha256.

    'This signature verifies against this public key' says nothing about whether
    that public key is still the project's root. The allowlist is the only place
    that answers it, so a superseded or lost root cannot be accepted again by
    accident (the retired roots are recorded in REVOKED-KEYS.md). A source tree
    without the allowlist -- e.g. a checkout of this tool alone -- keeps the old
    behaviour: no pin is applied.
    """
    if not TRUSTED_KEYS_FILE.is_file():
        return True, ""
    try:
        want = {ln.split()[0].lower() for ln in TRUSTED_KEYS_FILE.read_text().splitlines()
                if ln.strip() and not ln.lstrip().startswith("#")}
        got = hashlib.sha256(Path(key_path).read_bytes()).hexdigest()
    except OSError as e:
        return False, f"trusted key could not be read for pinning: {e}"
    if got not in want:
        return False, (f"trusted key {got[:16]}… is not in release/trusted-keys.sha256: "
                       "superseded or unknown root, see release/REVOKED-KEYS.md")
    return True, ""


def verify_signature(doc_path, trusted_key):
    """(ok, reason): doc_path + '.sig' is an Ed25519 signature over doc_path by
    the operator-supplied trusted public key (PEM). The key must not come from
    the evidence directory; it is what makes the content someone's statement
    rather than just a file whose hash matches itself."""
    if not trusted_key:
        return False, "no trusted public key given (--trusted-key): unsigned input is not evidence"
    sig = Path(str(doc_path) + ".sig")
    if not sig.is_file():
        return False, f"detached signature missing: {sig.name}"
    try:
        r = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(trusted_key),
             "-rawin", "-in", str(doc_path), "-sigfile", str(sig)],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, f"signature check could not run: {e}"
    if r.returncode != 0:
        return False, "signature does not verify against the trusted key"
    ok, why = pinned_key_problem(trusted_key)
    if not ok:
        return False, why
    return True, ""


def _bound_file(base, rel, want_sha):
    """(path|None, reason): rel exists under base (no escape) and hashes to want_sha."""
    if not isinstance(rel, str) or not rel or not isinstance(want_sha, str) \
            or not HEX64.match(want_sha):
        return None, "file or sha256 missing/malformed"
    base = Path(base).resolve()
    path = (base / rel).resolve()
    if base != path and base not in path.parents:
        return None, "file path escapes the evidence directory"
    if not path.is_file():
        return None, f"file not found: {rel}"
    if sha256_of(path) != want_sha:
        return None, f"sha256 mismatch for {rel}"
    return path, ""


def _load_json(path):
    try:
        return json.loads(Path(path).read_text()), None
    except (OSError, ValueError) as e:
        return None, f"unreadable: {e}"


def parse_test_results(path):
    """Authoritative outcome of a machine-written test result, recounted from
    the individual test cases: {"cases": {name: passed|failed|skipped}, counts}.

    Understands JUnit XML (testsuite/testsuites) and Robot Framework
    output.xml. Raises ValueError for anything malformed, ambiguous (duplicate
    case names), or self-contradictory (suite totals that disagree with the
    cases listed). Nothing here trusts a summary line over the cases.
    """
    import xml.etree.ElementTree as ET
    raw = Path(path).read_bytes()
    if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise ValueError("DTD/entity declarations are not accepted")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        raise ValueError(f"not well-formed XML: {e}")
    cases = {}

    def add(name, outcome):
        if not name or name in cases:
            raise ValueError(f"missing or duplicate test case name: {name!r}")
        cases[name] = outcome

    if root.tag in ("testsuite", "testsuites"):
        suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
        for su in suites:
            direct = su.findall("testcase")
            n_fail = n_skip = 0
            for tc in direct:
                name = f"{tc.get('classname', '')}.{tc.get('name', '')}"
                kids = {c.tag for c in tc}
                if kids & {"failure", "error"}:
                    out = "failed"; n_fail += 1
                elif "skipped" in kids:
                    out = "skipped"; n_skip += 1
                else:
                    out = "passed"
                add(name, out)
            for attr, got in (("tests", len(direct)),
                              ("failures", sum(1 for t in direct if t.find("failure") is not None)),
                              ("errors", sum(1 for t in direct if t.find("error") is not None)),
                              ("skipped", n_skip)):
                if su.get(attr) is not None:
                    try:
                        claimed = int(su.get(attr))
                    except ValueError:
                        raise ValueError(f"non-numeric {attr} attribute")
                    if claimed != got:
                        raise ValueError(
                            f"suite {su.get('name')!r} claims {attr}={claimed} "
                            f"but its test cases give {got}")
    elif root.tag == "robot":
        for t in root.iter("test"):
            st = t.find("status")
            if st is None or st.get("status") not in ("PASS", "FAIL", "SKIP", "NOT RUN"):
                raise ValueError(f"robot test {t.get('name')!r} has no valid status")
            out = {"PASS": "passed", "FAIL": "failed"}.get(st.get("status"), "skipped")
            add(t.get("id") or t.get("name"), out)
    else:
        raise ValueError(f"unrecognised result format (root <{root.tag}>)")
    counts = {"total": len(cases)}
    for k in ("passed", "failed", "skipped"):
        counts[k] = sum(1 for v in cases.values() if v == k)
    return {"cases": cases, "counts": counts}


SUITE_CONFIG_FORMAT = "danos-suite-config-v1"


def load_suite_config(path, evidence_path=None):
    """Load the trusted definition of what each item's suite must cover.

    This is project configuration, reviewed and held by the release operator
    (--suite-config), NOT something the evidence signer supplies: the signer
    says what ran, the config says what had to run. Per item: min_cases (int
    >= 1), required_cases (non-empty, unique names that must all pass) and an
    optional suite_commit pin. The file may not live next to the evidence it
    judges. Returns ({item: entry}, sha256, errors).
    """
    path = Path(path)
    if evidence_path is not None:
        ev_dir = Path(evidence_path).resolve().parent
        here = path.resolve()
        if here.parent == ev_dir or ev_dir in here.parents:
            return {}, None, ["suite config must not be inside the evidence directory"]
    doc, err = _load_json(path)
    if err or not isinstance(doc, dict) or doc.get("format") != SUITE_CONFIG_FORMAT \
            or not isinstance(doc.get("items"), dict):
        return {}, None, [err or f"not a {SUITE_CONFIG_FORMAT} document"]
    known = {i for _, i, st, _ in VERIFICATION_ITEMS if i not in SCRIPT_OUTPUT_ROWS}
    items, errors = {}, []
    for item, e in doc["items"].items():
        req = e.get("required_cases") if isinstance(e, dict) else None
        if item not in known:
            errors.append(f"{item}: not a measured verification item"); continue
        if not isinstance(req, list) or not req or not all(isinstance(c, str) and c for c in req) \
                or len(set(req)) != len(req):
            errors.append(f"{item}: required_cases must be a non-empty list of unique names"); continue
        n = e.get("min_cases")
        if not isinstance(n, int) or isinstance(n, bool) or n < 1 or n < len(req):
            errors.append(f"{item}: min_cases must be an int >= max(1, len(required_cases))"); continue
        pin = e.get("suite_commit")
        if pin is not None and not (isinstance(pin, str) and HEX40.match(pin)):
            errors.append(f"{item}: suite_commit pin is not a 40-hex commit"); continue
        items[item] = {"min_cases": n, "required_cases": list(req), "suite_commit": pin}
    return items, sha256_of(path), errors


def load_evidence(path, iso_sha256, trusted_key=None, suite_config=None):
    """Validate a signed verification-evidence file against one actual ISO.

    The document must carry a valid detached signature from the trusted key.
    For each record: the ISO digest must match, the suite commit must be
    named, the raw result file must hash correctly AND parse as JUnit/Robot
    output; pass/fail counts are *derived from the parsed cases*, never taken
    from the record, and a declared status or count that contradicts them
    rejects the record. A PASS additionally needs the item's entry in the
    trusted suite_config (see load_suite_config): at least min_cases passing
    cases, every required case present and passing, and the pinned suite
    commit if the config has one. Anything the record says about required
    cases or minimum sizes is ignored. Returns (accepted, rejected):
    {item: record+derived}, [(item, why)].
    """
    accepted, rejected = {}, []
    if not iso_sha256 or not HEX64.match(iso_sha256):
        return accepted, [("*", "ISO sha256 not available")]
    ok, why = verify_signature(path, trusted_key)
    if not ok:
        return accepted, [("*", why)]
    doc, err = _load_json(path)
    if err or not isinstance(doc, dict) or doc.get("format") != EVIDENCE_FORMAT \
            or not isinstance(doc.get("records"), list):
        return accepted, [("*", err or f"not a {EVIDENCE_FORMAT} document")]
    known = {i for _, i, st, _ in VERIFICATION_ITEMS if i not in SCRIPT_OUTPUT_ROWS}
    base = Path(path).parent
    for rec in doc["records"]:
        item = rec.get("item") if isinstance(rec, dict) else None

        def reject(why):
            rejected.append((item or "?", why))
        if item not in known:
            reject("unknown or non-measured item"); continue
        if item in accepted:
            reject("duplicate record for item"); continue
        if rec.get("iso_sha256") != iso_sha256:
            reject("iso_sha256 does not match this ISO"); continue
        if not isinstance(rec.get("suite_commit"), str) or not HEX40.match(rec["suite_commit"]):
            reject("suite_commit missing or not a 40-hex commit"); continue
        if rec.get("status") not in ("PASS", "FAIL"):
            reject("status must be PASS or FAIL"); continue
        rpath, why = _bound_file(base, rec.get("result_file"), rec.get("result_sha256"))
        if rpath is None:
            reject(why); continue
        try:
            parsed = parse_test_results(rpath)
        except (ValueError, OSError) as e:
            reject(f"result file rejected: {e}"); continue
        counts = parsed["counts"]
        derived = "PASS" if counts["total"] > 0 and counts["passed"] == counts["total"] else "FAIL"
        if rec["status"] != derived:
            reject(f"declared {rec['status']} contradicts the parsed results ({counts})"); continue
        if "cases" in rec and rec["cases"] != counts:
            reject(f"declared case counts contradict the parsed results ({counts})"); continue
        if derived == "PASS":
            want = (suite_config or {}).get(item)
            if want is None:
                reject("PASS needs a trusted suite definition for this item "
                       "(--suite-config); signer-supplied coverage is not used"); continue
            if want["suite_commit"] and rec["suite_commit"] != want["suite_commit"]:
                reject("suite_commit differs from the commit the suite config pins"); continue
            if counts["passed"] < want["min_cases"]:
                reject(f"only {counts['passed']} passing cases, {item} needs at least "
                       f"{want['min_cases']}"); continue
            bad = [c for c in want["required_cases"] if parsed["cases"].get(c) != "passed"]
            if bad:
                reject(f"required cases missing or not passing: {bad[:5]}"); continue
        accepted[item] = {**rec, "status": derived, "cases": counts}
    return accepted, rejected


def parse_buildinfo(path):
    """Source, Version and Binary fields of a Debian .buildinfo (a PGP
    clearsign wrapper, if any, is skipped but NOT verified here)."""
    fields = {}
    for line in Path(path).read_text(errors="replace").splitlines():
        m = re.match(r"^(Source|Version|Binary):\s*(.+?)\s*$", line)
        if m and m.group(1) not in fields:
            fields[m.group(1)] = m.group(2)
    if not {"Source", "Version", "Binary"} <= set(fields):
        raise ValueError("buildinfo lacks Source/Version/Binary")
    return {"source": fields["Source"].split()[0],
            "version": fields["Version"],
            "binaries": set(re.split(r"[,\s]+", fields["Binary"]))}


def load_provenance(path, iso_sha256, trusted_key=None):
    """Validate signed build provenance: ({(name, version): entry}, rejected).

    The document must be signed by the trusted build key and name the ISO's
    digest. Each entry must also be corroborated by a hash-matching Debian
    .buildinfo whose Source, Binary list and source Version agree with the
    entry (so the entry cannot claim a different package or version than the
    build record shows). This yields a *claim* only: resolve_source never marks
    a source attribution verified from it, because the commit is the signer's
    statement and nothing links it to the built .deb or the ISO's package.
    """
    out, rejected = {}, []
    if not iso_sha256 or not HEX64.match(iso_sha256):
        return out, [("*", "ISO sha256 not available")]
    ok, why = verify_signature(path, trusted_key)
    if not ok:
        return out, [("*", why)]
    doc, err = _load_json(path)
    if err or not isinstance(doc, dict) or doc.get("format") != PROVENANCE_FORMAT \
            or not isinstance(doc.get("packages"), list):
        return out, [("*", err or f"not a {PROVENANCE_FORMAT} document")]
    if doc.get("iso_sha256") != iso_sha256:
        return out, [("*", "provenance iso_sha256 does not match this ISO")]
    base = Path(path).parent
    for e in doc["packages"]:
        if not isinstance(e, dict):
            rejected.append(("?", "entry is not an object")); continue
        key = (e.get("name"), e.get("version"))
        label = f"{key[0]} {key[1]}"
        if not all(isinstance(k, str) and k for k in key + (
                e.get("source_package"), e.get("source_version"))):
            rejected.append((label, "name/version/source_package/source_version missing")); continue
        if not isinstance(e.get("commit"), str) or not HEX40.match(e["commit"]):
            rejected.append((label, "commit missing or not 40-hex")); continue
        bpath, why = _bound_file(base, e.get("buildinfo_file"), e.get("buildinfo_sha256"))
        if bpath is None:
            rejected.append((label, why)); continue
        try:
            bi = parse_buildinfo(bpath)
        except (ValueError, OSError) as ex:
            rejected.append((label, f"buildinfo rejected: {ex}")); continue
        if bi["source"] != e["source_package"] or bi["version"] != e["source_version"] \
                or e["name"] not in bi["binaries"]:
            rejected.append((label, "buildinfo Source/Version/Binary contradict the entry")); continue
        out[key] = e
    return out, rejected


def build_verification_summary(iso_name=None, iso_sha256=None, evidence=None):
    """Rows for a release. A measured row leaves NOT_RUN only through a record
    in `evidence` (the accepted dict from load_evidence, already validated
    against this ISO); the image name never counts as evidence."""
    evidence = evidence or {}
    rows = []
    for phase, item, status, note in VERIFICATION_ITEMS:
        row = {"phase": phase, "item": item, "status": status, "note": note}
        if item in evidence and item not in SCRIPT_OUTPUT_ROWS and iso_sha256:
            rec = evidence[item]
            c = rec["cases"]
            row["status"] = rec["status"]
            row["note"] = (
                f"{c['passed']}/{c['total']} passed, {c['failed']} failed, "
                f"{c['skipped']} skipped on ISO sha256 {iso_sha256}; suite commit "
                f"{rec['suite_commit']}; raw result {rec['result_file']} "
                f"sha256 {rec['result_sha256']}"
            )
            rows.append(row)
            continue
        if status == "PASS" and item not in SCRIPT_OUTPUT_ROWS:
            row["status"] = "NOT_RUN"
            row["note"] = (
                "no artifact-bound evidence for this image"
                + (f" ({iso_name}, sha256 {iso_sha256 or 'not checked'})" if iso_name else "")
                + "; the recorded result below is historical and inherited, not current"
            )
            row["historical"] = {
                "status": status,
                "note": note,
                "recorded_for": sorted(HISTORICAL_IMAGE_NOTES),
            }
            for name, over in HISTORICAL_OVERRIDES.items():
                if item in over:
                    row["historical"].setdefault("per_image", {})[name] = {
                        "status": over[item][0], "note": over[item][1]}
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("iso", type=Path, help="built ISO to assemble a release for")
    ap.add_argument(
        "--out", type=Path,
        default=Path("/home/aikon/danos/releases"),
        help="parent directory for the release folder (default: %(default)s)",
    )
    ap.add_argument(
        "--link", action="store_true",
        help="hardlink the ISO into the release dir instead of copying "
             "(same filesystem only; default copies)",
    )
    ap.add_argument("--obs-dir", type=Path, default=DEFAULT_OBS_DIR)
    ap.add_argument("--obs-repo", type=Path, default=DEFAULT_OBS_REPO)
    ap.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    ap.add_argument("--sources", type=Path, default=DEFAULT_SOURCES)
    ap.add_argument("--trusted-key", type=Path, default=None,
                    help="PEM Ed25519 public key whose signature (<file>.sig) makes "
                         "--evidence / --build-provenance trustworthy; kept outside them")
    ap.add_argument("--suite-config", type=Path, default=None,
                    help="trusted project suite definition (required cases and minimum "
                         "counts per item); without it no PASS evidence is accepted")
    ap.add_argument("--evidence", type=Path, default=None,
                    help="verification-evidence JSON bound to this ISO's sha256; "
                         "without it every measured row is NOT_RUN")
    ap.add_argument("--build-provenance", type=Path, default=None,
                    help="build-provenance JSON (commit + attestation hash per "
                         "package); without it no version-stamped commit is confirmed")
    ap.add_argument("--remote-check-tag-timeout", type=int, default=DEFAULT_TAG_TIMEOUT, metavar="SECONDS",
                    help="seconds allowed for each of the two tag passes (`git tag --contains`, `git for-each-ref refs/tags`) over a source repository's tags "
                         "(default %(default)s); on timeout or failure the capped tip-by-tip scan runs instead")
    ap.add_argument("--remote-check-tag-limit", type=int, default=DEFAULT_TAG_LIMIT, metavar="N",
                    help="most tag tips examined one by one when the one-pass answer is unavailable or a tag is not at the "
                         "remote's object (default %(default)s); a result that stopped there says 'checked N of M tag tips'")
    ap.add_argument("--no-remote-check", action="store_true",
                    help="skip the `git ls-remote` reachability check of local_git commits "
                         "(offline runs); those rows are then verified=false with that reason")
    args = ap.parse_args()

    if not args.iso.exists():
        sys.exit(f"no such ISO: {args.iso}")

    stem = args.iso.name.rsplit(".", 1)[0]  # i-danos_2608_<stamp>-amd64.hybrid[-test]
    manifest_path = args.iso.parent / f"{stem.split('-amd64')[0]}-amd64.packages"
    if not manifest_path.exists():
        sys.exit(f"no manifest next to the ISO: {manifest_path}")

    release_dir = args.out / stem
    release_dir.mkdir(parents=True, exist_ok=True)

    print(f"== {release_dir} ==")

    # 1. the ISO and its manifest, verbatim
    dest_iso = release_dir / args.iso.name
    if not dest_iso.exists():
        if args.link:
            import os
            os.link(args.iso, dest_iso)
        else:
            import shutil
            shutil.copy2(args.iso, dest_iso)
    (release_dir / "manifest.txt").write_text(manifest_path.read_text())
    print(f"  iso + manifest.txt")
    iso_sha = sha256_of(dest_iso)

    # 2. resolve every installed package
    repo_index = parse_repo_packages(args.obs_repo / "Packages")
    commit_index = index_commit_files(args.obs_dir / "dsc")
    commits_by_source = index_commits_by_source(commit_index)
    baseline = parse_baseline(args.baseline)
    provenance, prov_rejected = ({}, [])
    if args.build_provenance:
        provenance, prov_rejected = load_provenance(args.build_provenance, iso_sha, args.trusted_key)
    with tempfile.TemporaryDirectory(dir=release_dir) as tmp:
        apt_dir = Path(tmp) / "apt"
        records = read_image(args.iso, tmp, apt_dir)
        installed = [(r["name"], r["version"]) for r in records]
        apt_index, apt_releases = load_apt_index(apt_dir)
    listed = {n.split(":")[0]: v for n, v in parse_iso_manifest(manifest_path)}
    actual = dict(installed)
    diff = {
        "note": "the ISO's .packages manifest is a mid-build snapshot; the SBOM uses the image's own dpkg status",
        "only_in_image": sorted(set(actual) - set(listed)),
        "only_in_manifest": sorted(set(listed) - set(actual)),
        "version_differs": sorted(p for p in actual if p in listed and actual[p] != listed[p]),
    }
    (release_dir / "manifest-vs-image.json").write_text(json.dumps(diff, indent=2))
    print(f"  manifest-vs-image.json  ({len(diff['only_in_image'])} in the image but not the manifest, "
          f"{len(diff['only_in_manifest'])} the other way)")

    sbom_rows = []
    revmap_rows = []
    category_counts = {}
    for name, version in installed:
        resolved = resolve_source(name, version, repo_index, commit_index, baseline,
                                   commits_by_source, provenance)
        category_counts[resolved["category"]] = (
            category_counts.get(resolved["category"], 0) + 1
        )
        sbom_rows.append({
            "name": name,
            "version": version,
            "source_package": resolved["source_package"],
            "provenance": resolved["category"],
        })
        row = {"name": name, "version": version, **resolved}
        revmap_rows.append(row)

    prov_rows = enrich_rows(revmap_rows, records, apt_index, apt_releases, args.sources,
                            remote_check=not args.no_remote_check,
                            checker=functools.partial(check_commit_published, tag_timeout=args.remote_check_tag_timeout,
                                                      tag_limit=args.remote_check_tag_limit))
    vsum = verified_summary(revmap_rows)
    (release_dir / "provenance.json").write_text(json.dumps({
        "format": "danos-p0.5-package-provenance-v1",
        "verified_definition": VERIFIED_DEFINITION,
        "debian_releases": apt_releases,
        "packages": prov_rows,
    }, indent=2))

    (release_dir / "sbom.json").write_text(
        json.dumps({"format": "danos-p0.5-sbom-v1", "packages": sbom_rows}, indent=2)
    )
    (release_dir / "source-revision-map.json").write_text(
        json.dumps({
            "format": "danos-p0.5-source-revision-map-v1",
            "category_counts": category_counts,
            "verified_counts": vsum,
            "verified_definition": VERIFIED_DEFINITION,
            "provenance_file": "provenance.json",
            "packages": revmap_rows,
        }, indent=2)
    )
    print(f"  sbom.json + source-revision-map.json + provenance.json  ({len(installed)} packages)")
    print(f"    verified: {vsum['true']} true / {vsum['false']} false")
    for cat, n in sorted(category_counts.items(), key=lambda kv: -kv[1]):
        print(f"    {cat:22s} {n}")

    # 3. build inputs
    build_inputs = build_build_inputs(args.sources, args.obs_repo, args.obs_dir)
    (release_dir / "build-inputs.json").write_text(
        json.dumps(build_inputs, indent=2)
    )
    print("  build-inputs.json")

    # 4. verification summary
    accepted, ev_rejected, suite_sha = ({}, [], None)
    if args.evidence:
        suites, suite_sha, suite_errors = ({}, None, ["--suite-config not given"])
        if args.suite_config:
            suites, suite_sha, suite_errors = load_suite_config(args.suite_config, args.evidence)
        accepted, ev_rejected = load_evidence(args.evidence, iso_sha, args.trusted_key, suites)
        ev_rejected += [("suite-config", e) for e in suite_errors]
    summary = build_verification_summary(args.iso.name, iso_sha, accepted)
    not_run = sum(1 for s in summary if s["status"] == "NOT_RUN")
    (release_dir / "verification-summary.json").write_text(
        json.dumps({
            "format": "danos-p0.5-verification-summary-v1",
            "iso_sha256": iso_sha,
            "suite_config_sha256": suite_sha,
            "evidence_rejected": [{"item": i, "reason": r} for i, r in ev_rejected],
            "provenance_rejected": [{"package": i, "reason": r} for i, r in prov_rejected],
            "items": summary,
        }, indent=2)
    )
    print(f"  verification-summary.json  ({len(summary)} items, {not_run} NOT_RUN)")

    print(f"\ndone: {release_dir}")


if __name__ == "__main__":
    main()
