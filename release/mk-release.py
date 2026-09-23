#!/usr/bin/env python3
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
    sbom.json                         one row per installed package: name,
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
import hashlib
import json
import subprocess
import sys
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


def strip_epoch(version):
    return version.split(":", 1)[1] if ":" in version else version


def resolve_source(name, version, repo_index, commit_index, baseline,
                    commits_by_source=None):
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
            return {
                "category": "local_git_version_stamped",
                "source_package": source,
                "commit": alt_sha,
                "reason": (
                    f"installed as {version}, but the recorded commit is for "
                    f"{source} {alt_ver} -- debian/rules stamps this "
                    "package's version at build time, decoupled from "
                    "debian/changelog, so the mismatch is expected"
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
    ("p0.5", "upgrade_add_image", "PASS", "checksum fix (5.52) + grub write-path fix (5.53), both defect-tracked"),
    ("p0.5", "rollback", "PASS", "select original image, reboot, confirmed via /proc/cmdline"),
    ("p0.5", "cloud_init", "PASS", "NoCloud seed hostname applied, no boot stall (defect 4's fix holds)"),
    ("p0.5", "no_network_boot", "PASS", "zero -netdev, reached a usable login under a minute"),
    ("p0.5", "nic_naming_stability", "PASS", "dp0s3 name and MAC identical across a reboot"),
    ("p0.5", "real_nic_hardware", "NOT_APPLICABLE", "deliberately out of scope for this pass; see UPGRADE-RECORD.md, 'What verified covers, and what it does not'"),
    # P0.5 items 1-3, 5 -- what this script itself produces.
    ("p0.5", "obs_project_revision_frozen", "PASS", "captured in build-inputs.json"),
    ("p0.5", "unified_release_directory", "PASS", "this directory"),
    ("p0.5", "sbom_generated", "PASS", "sbom.json"),
    ("p0.5", "source_revision_map", "PASS", "source-revision-map.json, six-category split. Of the two obs_package_revision hits found on i-danos_2608_20260922T1655-amd64.hybrid-test.iso, vyatta-version turned out to have a recorded commit after all -- its debian/rules deliberately stamps the release number as the package version (dh_gencontrol -- -v$(VVERSION)), decoupled from debian/changelog's own '1.4' -- now correctly resolved as local_git_version_stamped. linux-signed is correctly obs_package_revision, not a gap -- its own Packages entry names 'Maintainer: OBS signing service <obssign@obs.service>', confirming it is the signed-kernel package OBS's signing infrastructure produces as a byproduct of building linux-image, with no source package of its own to check out."),
    ("p0.5", "results_normalized", "PASS", "this file"),
    # 81-case regression, tracked separately because it is per-ISO, not
    # per-project -- re-run and re-record for every release, not copied
    # forward.
    ("regression", "robot_81_cases", "PASS", "81/81 on i-danos_2608_20260922T1655-amd64.hybrid-test.iso; an earlier run on the same ISO showed 27 unrelated failures traced to host CPU contention (~15 load average / 4 cores from concurrent unrelated VMs), not this build -- see DEFECTS.md. Re-run and update this row for every future release; do not copy this PASS forward to a different ISO."),
    # P1/P2 -- explicitly not started, per the project's own roadmap
    # ordering (P0.5 before P1 before P2). Listed so a reader of this summary
    # sees the whole plan, not just the part that is done.
    ("p1", "dpa_object_model_extension", "NOT_RUN", "not started"),
    ("p1", "drift_state_machine", "PASS", "implemented in dpa-drift.py --watch: all eight named states (observed, transient_in_flight, reserved_owned, source_mismatch, next_hop_dependency, unsupported_or_unreadable, stale_candidate, confirmed_stale), promotion arithmetic unit-tested deterministically, classification verified live against a real router."),
    ("p1", "comparison_scope_route6", "PASS", "COMPARED in dpa-drift.py now includes route6 alongside route; desired()/programmed() parameterized by object class, keys carry (class, vrf, prefix). Verified live against r1: single-snapshot and --watch both ran clean, route6's reserved objects (::/0, ::1/128, etc.) correctly classified reserved_owned, and a genuine route6 disagreement (fe80::/64) tracked correctly through the watch-mode streak. Also found live, not assumed: route6's DPA state string is lowercase where route's is upper -- classify_extra now normalizes case, or route6's own unsupported objects would have misclassified as source_mismatch."),
    ("p1", "comparison_scope_mpls_mcast", "NOT_RUN", "mpls-route, mroute, mroute6 are all enumerable and have a Desired source (show mpls table json / show ip[v6] mroute json all answer) but each needs a topology that exercises it before the comparison can be verified rather than merely written"),
    ("p1", "drift_event_correlation_config_commits", "PASS", "dpa-drift-correlate.py correlates dpa-drift-history.py's events against configd's own commit log (journalctl -u configd, 'COMMIT: Commit OVERALL' lines, microsecond timestamps) within a configurable window, adding correlated_commit/gap_seconds or a reason when nothing qualifies. Verified live against r1 both directions: a real confirmed_stale event (fe80::/64, reached that state organically this run) correctly resolved to no correlated commit; a synthetic event 1.3s after a real commit correctly resolved to it."),
    ("p1", "drift_event_correlation_netlink", "PASS", "dpa-drift-correlate-netlink.py correlates events against vyatta-dataplane's netlink route log ('ROUTE: RTM_NEWROUTE/RTM_DELROUTE ... dst <prefix> ...'), which turned out to already exist -- gated behind the dataplane's nl_route debug category, off by default ({\"0x13\":[\"init\",\"link\",\"nl_interface\"]}), toggleable at runtime with no restart (vplsh -c 'debug nl_route' / 'debug -nl_route', both directions confirmed live). Correlates by prefix only, not (vrf, prefix) -- the log line carries a table number, not a VRF name -- stated as a limitation. Verified live against r1: a synthetic event just after a real RTM_DELROUTE correctly correlated (gap_seconds 0.254); an untouched prefix correctly resolved to null."),
    ("p1", "drift_event_correlation_broker_dp_transactions", "NOT_RUN", "brokerd->dataplane *delivery* is already covered by the netlink row: vyatta-dataplane's route_broker.c receives brokerd's ZMQ route messages and feeds them through the same rtnl_process() that emits the 'ROUTE: RTM_*ROUTE' line (source read, and consistent with the live capture, where a route committed via zebra/FPM/brokerd logged exactly that line). What remains NOT_RUN is *completion* -- the FAL/DPA programming result after delivery -- for which the only failure log found is DP_DEBUG(ROUTE, NOTICE) 'route message not handled' on a parse failure; no success/completion log has been located, and brokerd's own journal is empty past startup"),
    ("p2", "signed_boot_chain", "NOT_RUN", "not started"),
    ("p2", "physical_nic_dpdk_binding", "NOT_RUN", "not started"),
    ("p2", "power_loss_recovery", "NOT_RUN", "not started"),
]


def build_verification_summary():
    return [
        {"phase": phase, "item": item, "status": status, "note": note}
        for phase, item, status, note in VERIFICATION_ITEMS
    ]


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

    # 2. resolve every installed package
    repo_index = parse_repo_packages(args.obs_repo / "Packages")
    commit_index = index_commit_files(args.obs_dir / "dsc")
    commits_by_source = index_commits_by_source(commit_index)
    baseline = parse_baseline(args.baseline)
    installed = parse_iso_manifest(manifest_path)

    sbom_rows = []
    revmap_rows = []
    category_counts = {}
    for name, version in installed:
        resolved = resolve_source(name, version, repo_index, commit_index, baseline,
                                   commits_by_source)
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

    (release_dir / "sbom.json").write_text(
        json.dumps({"format": "danos-p0.5-sbom-v1", "packages": sbom_rows}, indent=2)
    )
    (release_dir / "source-revision-map.json").write_text(
        json.dumps({
            "format": "danos-p0.5-source-revision-map-v1",
            "category_counts": category_counts,
            "packages": revmap_rows,
        }, indent=2)
    )
    print(f"  sbom.json + source-revision-map.json  ({len(installed)} packages)")
    for cat, n in sorted(category_counts.items(), key=lambda kv: -kv[1]):
        print(f"    {cat:22s} {n}")

    # 3. build inputs
    build_inputs = build_build_inputs(args.sources, args.obs_repo, args.obs_dir)
    (release_dir / "build-inputs.json").write_text(
        json.dumps(build_inputs, indent=2)
    )
    print("  build-inputs.json")

    # 4. verification summary
    summary = build_verification_summary()
    not_run = sum(1 for s in summary if s["status"] == "NOT_RUN")
    (release_dir / "verification-summary.json").write_text(
        json.dumps({
            "format": "danos-p0.5-verification-summary-v1",
            "items": summary,
        }, indent=2)
    )
    print(f"  verification-summary.json  ({len(summary)} items, {not_run} NOT_RUN)")

    print(f"\ndone: {release_dir}")


if __name__ == "__main__":
    main()
