"""Negative regression tests for mk-release.py evidence handling (A01, A07).

Run: python3 -m unittest -v test_mk_release   (from this directory)
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "mk_release", Path(__file__).with_name("mk-release.py"))
mk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mk)

# Rows the script itself produces while assembling a release directory.
SCRIPT_OUTPUT_ROWS = {
    "obs_project_revision_frozen", "unified_release_directory",
    "sbom_generated", "source_revision_map", "results_normalized",
}


def statuses(iso_name):
    return {r["item"]: r["status"] for r in mk.build_verification_summary(iso_name)}


class VerificationSummaryTest(unittest.TestCase):
    def assert_no_inherited_pass(self, iso_name):
        for item, status in statuses(iso_name).items():
            if item in SCRIPT_OUTPUT_ROWS:
                continue
            self.assertNotEqual(
                status, "PASS", f"{item} carried PASS to unevidenced ISO {iso_name!r}")

    def test_unknown_iso_gets_no_inherited_pass(self):
        self.assert_no_inherited_pass("never-built-audit-input.iso")

    def test_missing_iso_name_gets_no_inherited_pass(self):
        self.assert_no_inherited_pass(None)

    def test_newer_real_looking_iso_gets_no_inherited_pass(self):
        self.assert_no_inherited_pass("i-danos_2608_20261016T1015-amd64.hybrid.iso")

    def test_inherited_rows_say_where_the_result_came_from(self):
        rows = {r["item"]: r for r in
                mk.build_verification_summary("never-built-audit-input.iso")}
        self.assertEqual(rows["robot_81_cases"]["status"], "NOT_RUN")
        self.assertIn("inherited", rows["robot_81_cases"]["note"].lower())

    def test_script_output_rows_stay_pass(self):
        s = statuses("never-built-audit-input.iso")
        for item in SCRIPT_OUTPUT_ROWS:
            self.assertEqual(s[item], "PASS", item)

    def test_non_pass_rows_are_not_upgraded(self):
        s = statuses("never-built-audit-input.iso")
        self.assertEqual(s["real_nic_hardware"], "NOT_APPLICABLE")
        self.assertEqual(s["dpa_object_model_extension"], "NOT_RUN")




class NameIsNotEvidenceTest(unittest.TestCase):
    SHA = "0" * 64
    NAMES = [
        mk.PRODUCT_ISO if hasattr(mk, "PRODUCT_ISO") else
        "i-danos_2608_20260926T0757-amd64.hybrid.iso",
        "i-danos_2608_20260926T0949-amd64.hybrid-test.iso",
    ]

    def test_known_names_get_no_pass_without_artifact_evidence(self):
        for name in self.NAMES:
            for sha in (None, self.SHA):
                rows = mk.build_verification_summary(name, sha)
                for r in rows:
                    if r["item"] in SCRIPT_OUTPUT_ROWS:
                        continue
                    self.assertNotEqual(r["status"], "PASS", (name, sha, r["item"]))

    def test_overridden_rows_are_not_current(self):
        name = "i-danos_2608_20260926T0949-amd64.hybrid-test.iso"
        rows = {r["item"]: r for r in mk.build_verification_summary(name, self.SHA)}
        for item in ("robot_81_cases", "disk_install_unattended", "rollback"):
            self.assertEqual(rows[item]["status"], "NOT_RUN", item)

    def test_history_is_kept_separately(self):
        name = "i-danos_2608_20260926T0949-amd64.hybrid-test.iso"
        rows = {r["item"]: r for r in mk.build_verification_summary(name, self.SHA)}
        self.assertEqual(rows["robot_81_cases"]["historical"]["status"], "PASS")
        self.assertIn(name, rows["robot_81_cases"]["historical"]["per_image"])


class SourceResolutionTest(unittest.TestCase):
    def resolve(self, name, source, installed, recorded):
        repo = {name: {"version": installed, "source": source}}
        commits = {(source, v): sha for v, sha in recorded}
        return mk.resolve_source(
            name, installed, repo, commits, {},
            mk.index_commits_by_source(commits))

    def test_unique_old_commit_is_not_confirmed(self):
        r = self.resolve("example", "example", "2.0", [("1.0", "a" * 40)])
        self.assertNotEqual(r["category"], "local_git_version_stamped")
        self.assertNotEqual(r["category"], "local_git")
        self.assertEqual(r["category"], "version_stamp_inferred")
        self.assertIs(r["verified"], False)
        self.assertNotIn("expected", r["reason"])

    def test_inferred_entry_does_not_claim_rules_rewrite_version(self):
        r = self.resolve("example", "example", "2.0", [("1.0", "a" * 40)])
        self.assertNotIn("stamps this package's version", r["reason"])
        self.assertIn("not verified", r["reason"])


    def test_vyatta_version_with_mismatched_version_is_not_confirmed(self):
        r = self.resolve("vyatta-version", "vyatta-version", "2608", [("1.4", "b" * 40)])
        self.assertEqual(r["category"], "version_stamp_inferred")
        self.assertIs(r["verified"], False)
        self.assertIn("rules_hint", r)

    def test_vyatta_version_other_unrecorded_version_is_not_confirmed(self):
        r = self.resolve("vyatta-version", "vyatta-version", "9999", [("0.1", "c" * 40)])
        self.assertNotEqual(r["category"], "local_git_version_stamped")

    def test_multiple_commits_stay_obs_revision(self):
        r = self.resolve("example", "example", "3.0",
                         [("1.0", "a" * 40), ("2.0", "b" * 40)])
        self.assertEqual(r["category"], "obs_package_revision")

    def test_exact_match_still_local_git(self):
        r = self.resolve("example", "example", "1.0", [("1.0", "a" * 40)])
        self.assertEqual(r["category"], "local_git")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def junit(cases, **suite_attrs):
    """cases: [(classname, name, 'passed'|'failed'|'error'|'skipped')]."""
    body = ""
    for cls, name, out in cases:
        inner = {"passed": "", "failed": "<failure message='x'/>",
                 "error": "<error message='x'/>", "skipped": "<skipped/>"}[out]
        body += f"<testcase classname='{cls}' name='{name}'>{inner}</testcase>"
    attrs = " ".join(f"{k}='{v}'" for k, v in suite_attrs.items())
    return f"<testsuite name='s' {attrs}>{body}</testsuite>".encode()


def robot(tests):
    body = "".join(f"<test id='s1-t{i}' name='{n}'><status status='{st}'/></test>"
                   for i, (n, st) in enumerate(tests, 1))
    return f"<robot><suite id='s1' name='x'>{body}</suite></robot>".encode()


class SignedDirMixin:
    def make_dir(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.dir = Path(self._td.name) / "ev"
        self.dir.mkdir()
        self.keys = Path(self._td.name) / "keys"
        self.keys.mkdir()
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out",
                        str(self.keys / "k.pem")], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", str(self.keys / "k.pem"), "-pubout",
                        "-out", str(self.keys / "k.pub")], check=True, capture_output=True)
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out",
                        str(self.keys / "evil.pem")], check=True, capture_output=True)
        self.pub = self.keys / "k.pub"
        # These keys are throwaway, so by design they are not in
        # release/trusted-keys.sha256; point the pin at a per-test allowlist that
        # lists this test's key, or every signature test would be rejected as a
        # retired root. TrustedKeyPinTest overrides it again on purpose.
        pin = self.keys / "trusted-keys.sha256"
        pin.write_text(hashlib.sha256(self.pub.read_bytes()).hexdigest() + "  test-key\n")
        self.addCleanup(setattr, mk, "TRUSTED_KEYS_FILE", mk.TRUSTED_KEYS_FILE)
        mk.TRUSTED_KEYS_FILE = pin

    def write_signed(self, name, doc, key="k.pem", sign=True):
        path = self.dir / name
        path.write_text(json.dumps(doc))
        if sign:
            subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(self.keys / key),
                            "-rawin", "-in", str(path), "-out", str(path) + ".sig"],
                           check=True, capture_output=True)
        return path


class EvidenceTest(SignedDirMixin, unittest.TestCase):
    ISO = sha(b"the iso bytes")
    COMMIT = "c" * 40

    def setUp(self):
        self.make_dir()
        self.cases = [("robot", f"case{i}", "passed") for i in range(81)]
        self.write_result("robot.xml", junit(self.cases))

    def write_result(self, name, data):
        (self.dir / name).write_bytes(data)
        return sha(data)

    def record(self, **over):
        r = {"item": "robot_81_cases", "status": "PASS", "iso_sha256": self.ISO,
             "suite_commit": self.COMMIT, "result_file": "robot.xml",
             "result_sha256": sha((self.dir / "robot.xml").read_bytes())}
        r.update(over)
        return r

    def write_config(self, names=None, min_cases=81, pin=None, name="suite.json",
                     where=None, items=None):
        entry = {"min_cases": min_cases,
                 "required_cases": names if names is not None
                 else [f"robot.case{i}" for i in range(81)]}
        if pin:
            entry["suite_commit"] = pin
        doc = {"format": mk.SUITE_CONFIG_FORMAT,
               "items": items if items is not None else {"robot_81_cases": entry}}
        path = (where or self.keys) / name   # operator-held, outside the evidence dir
        path.write_text(json.dumps(doc))
        return path

    def load(self, *records, iso=None, sign=True, key="k.pem", trusted=True, doc_over=None,
             config="default"):
        if config == "default":
            config = self.write_config()
        suites = mk.load_suite_config(config)[0] if config else None
        doc = {"format": mk.EVIDENCE_FORMAT, "records": list(records)}
        doc.update(doc_over or {})
        path = self.write_signed("evidence.json", doc, key=key, sign=sign)
        return mk.load_evidence(path, self.ISO if iso is None else iso,
                                self.pub if trusted else None, suites)

    def row(self, accepted, item="robot_81_cases"):
        rows = {r["item"]: r for r in mk.build_verification_summary("any.iso", self.ISO, accepted)}
        return rows[item]

    def assert_rejected(self, fragment, *records, **kw):
        acc, rej = self.load(*records, **kw)
        self.assertNotIn("robot_81_cases", acc)
        self.assertTrue(any(fragment in r for _, r in rej), rej)
        self.assertEqual(self.row(acc)["status"], "NOT_RUN")

    # -- accepted
    def test_valid_signed_junit_is_accepted_with_derived_counts(self):
        acc, rej = self.load(self.record())
        self.assertEqual(rej, [])
        row = self.row(acc)
        self.assertEqual(row["status"], "PASS")
        for needle in (self.ISO, self.COMMIT, "81/81"):
            self.assertIn(needle, row["note"])

    def test_valid_robot_output_is_accepted(self):
        tests = [(f"t{i}", "PASS") for i in range(81)]
        sh = self.write_result("out.xml", robot(tests))
        cfg = self.write_config(names=[f"s1-t{i}" for i in range(1, 82)])
        acc, rej = self.load(self.record(result_file="out.xml", result_sha256=sh), config=cfg)
        self.assertEqual(rej, [])
        self.assertEqual(acc["robot_81_cases"]["cases"]["total"], 81)

    # -- forged PASS
    def test_declared_pass_over_failing_results_is_rejected(self):
        bad = self.cases[:80] + [("robot", "case80", "failed")]
        sh = self.write_result("robot.xml", junit(bad))
        self.assert_rejected("contradicts", self.record(result_sha256=sh))

    def test_declared_pass_over_error_or_skip_is_rejected(self):
        for out in ("error", "skipped"):
            bad = self.cases[:80] + [("robot", "case80", out)]
            sh = self.write_result("robot.xml", junit(bad))
            self.assert_rejected("contradicts", self.record(result_sha256=sh))

    def test_declared_counts_contradicting_results_are_rejected(self):
        sh = self.write_result("robot.xml", junit(self.cases[:10]))
        self.assert_rejected(
            "declared case counts",
            self.record(result_sha256=sh,
                        cases={"total": 81, "passed": 81, "failed": 0, "skipped": 0}))

    def test_suite_attributes_lying_about_totals_are_rejected(self):
        sh = self.write_result("robot.xml", junit(self.cases[:10], tests=81, failures=0))
        self.assert_rejected("claims tests=81", self.record(result_sha256=sh))
        bad = self.cases[:9] + [("robot", "x", "failed")]
        sh = self.write_result("robot.xml", junit(bad, tests=10, failures=0))
        self.assert_rejected("claims failures=0", self.record(result_sha256=sh))

    def test_empty_or_zero_case_results_are_rejected(self):
        sh = self.write_result("robot.xml", junit([]))
        self.assert_rejected("contradicts", self.record(result_sha256=sh))

    def test_declared_fail_over_passing_results_is_rejected(self):
        self.assert_rejected("contradicts", self.record(status="FAIL"))

    def test_malformed_xml_and_unknown_format_are_rejected(self):
        for data in (b"not xml", b"<html/>", b"<testsuite><testcase></testsuite>"):
            sh = self.write_result("robot.xml", data)
            self.assert_rejected("result file rejected", self.record(result_sha256=sh))

    def test_entity_bomb_is_rejected_without_expansion(self):
        data = (b'<!DOCTYPE x [<!ENTITY a "aaaa">]><testsuite><testcase classname="c" name="n"/>'
                b'</testsuite>')
        sh = self.write_result("robot.xml", data)
        self.assert_rejected("DTD/entity", self.record(result_sha256=sh))

    def test_duplicate_case_names_are_rejected(self):
        sh = self.write_result("robot.xml", junit([("c", "n", "passed")] * 2))
        self.assert_rejected("duplicate", self.record(result_sha256=sh))

    # -- coverage comes from the trusted config, not from the signer
    def test_required_case_missing_from_results_is_rejected(self):
        cfg = self.write_config(names=[f"robot.case{i}" for i in range(81)] + ["robot.extra"],
                                min_cases=82)
        self.assert_rejected("only 81 passing", self.record(), config=cfg)
        cfg = self.write_config(names=["robot.extra"] + [f"robot.case{i}" for i in range(80)])
        self.assert_rejected("required cases missing", self.record(), config=cfg)

    def test_single_passing_case_cannot_mark_the_item_pass(self):
        sh = self.write_result("robot.xml", junit([("robot", "case0", "passed")]))
        self.assert_rejected("only 1 passing", self.record(result_sha256=sh))

    def test_signer_supplied_small_manifest_is_ignored(self):
        # a signed record that declares its own tiny "required" suite
        sh = self.write_result("robot.xml", junit([("robot", "case0", "passed")]))
        self.write_result("req.txt", b"robot.case0")
        self.assert_rejected("only 1 passing", self.record(
            result_sha256=sh, required_cases_file="req.txt",
            required_cases_sha256=sha(b"robot.case0"), min_cases=1,
            required_cases=["robot.case0"]))

    def test_signer_cannot_lower_the_minimum_or_relax_the_list(self):
        sh = self.write_result("robot.xml", junit(self.cases[:80]))
        self.assert_rejected("only 80 passing", self.record(
            result_sha256=sh, min_cases=80))

    def test_pass_without_any_trusted_suite_config_is_rejected(self):
        self.assert_rejected("trusted suite definition", self.record(), config=None)

    def test_pass_for_an_item_the_config_does_not_define_is_rejected(self):
        cfg = self.write_config(items={})
        self.assert_rejected("trusted suite definition", self.record(), config=cfg)

    def test_config_pin_must_match_the_suite_commit(self):
        cfg = self.write_config(pin="e" * 40)
        self.assert_rejected("pins", self.record(), config=cfg)
        cfg = self.write_config(pin=self.COMMIT)
        acc, rej = self.load(self.record(), config=cfg)
        self.assertEqual(rej, [])

    def test_recorded_fail_needs_no_suite_definition(self):
        bad = self.cases[:80] + [("robot", "case80", "failed")]
        sh = self.write_result("robot.xml", junit(bad))
        acc, _ = self.load(self.record(status="FAIL", result_sha256=sh), config=None)
        self.assertEqual(self.row(acc)["status"], "FAIL")

    def test_malformed_suite_configs_define_nothing(self):
        e = {"min_cases": 2, "required_cases": ["a", "b"]}
        bad_items = [
            {"robot_81_cases": {"min_cases": 81, "required_cases": []}},
            {"robot_81_cases": {"min_cases": 81}},
            {"robot_81_cases": {"min_cases": 1, "required_cases": ["a", "b"]}},
            {"robot_81_cases": {"min_cases": 2, "required_cases": ["a", "a"]}},
            {"robot_81_cases": {"min_cases": True, "required_cases": ["a"]}},
            {"robot_81_cases": {"min_cases": 1, "required_cases": ["a"], "suite_commit": "x"}},
            {"sbom_generated": e},
            {"no_such_item": e},
        ]
        for items in bad_items:
            cfg = self.write_config(items=items)
            suites, _, errors = mk.load_suite_config(cfg)
            self.assertEqual(suites, {}, items)
            self.assertTrue(errors, items)
        (self.keys / "g.json").write_text("not json")
        self.assertEqual(mk.load_suite_config(self.keys / "g.json")[0], {})

    def test_suite_config_inside_the_evidence_directory_is_refused(self):
        cfg = self.write_config(where=self.dir)
        ev = self.dir / "evidence.json"
        suites, _, errors = mk.load_suite_config(cfg, ev)
        self.assertEqual(suites, {})
        self.assertTrue(any("inside the evidence directory" in e for e in errors))

    def test_suite_config_outside_is_accepted_and_hashed(self):
        cfg = self.write_config()
        suites, digest, errors = mk.load_suite_config(cfg, self.dir / "evidence.json")
        self.assertEqual((errors, digest), ([], sha(cfg.read_bytes())))
        self.assertEqual(suites["robot_81_cases"]["min_cases"], 81)

    # -- authenticity
    def test_unsigned_evidence_is_rejected(self):
        self.assert_rejected("signature missing", self.record(), sign=False)

    def test_no_trusted_key_rejects_everything(self):
        self.assert_rejected("no trusted public key", self.record(), trusted=False)

    def test_signature_by_another_key_is_rejected(self):
        self.assert_rejected("does not verify", self.record(), key="evil.pem")

    def test_edit_after_signing_is_rejected(self):
        path = self.write_signed("evidence.json",
                                 {"format": mk.EVIDENCE_FORMAT, "records": [self.record()]})
        path.write_text(path.read_text().replace(self.COMMIT, "d" * 40))
        acc, rej = mk.load_evidence(path, self.ISO, self.pub)
        self.assertEqual(acc, {})
        self.assertTrue(any("does not verify" in r for _, r in rej))

    # -- binding
    def test_other_or_changed_iso_is_rejected(self):
        self.assert_rejected("iso_sha256", self.record(iso_sha256=sha(b"other")))
        self.assert_rejected("iso_sha256", self.record(), iso=sha(b"rebuilt, same name"))

    def test_tampered_missing_or_escaping_result_file_is_rejected(self):
        (self.dir / "robot.xml").write_bytes(junit(self.cases[:5]))
        self.assert_rejected("sha256 mismatch", self.record(result_sha256=sha(b"stale")))
        self.assert_rejected("not found", self.record(result_file="gone.xml"))
        outside = self.dir.parent / "outside.xml"
        outside.write_bytes(junit(self.cases))
        self.assert_rejected("escapes", self.record(
            result_file="../outside.xml", result_sha256=sha(outside.read_bytes())))

    def test_bad_suite_commit_unknown_item_or_duplicate(self):
        self.assert_rejected("suite_commit", self.record(suite_commit="main"))
        for item in ("sbom_generated", "no_such_item"):
            acc, rej = self.load(self.record(item=item))
            self.assertEqual(acc, {})
            self.assertTrue(rej)
        acc, rej = self.load(self.record(), self.record())
        self.assertTrue(any("duplicate" in r for _, r in rej))

    def test_recorded_failure_is_reported_as_fail(self):
        bad = self.cases[:79] + [("robot", "a", "failed"), ("robot", "b", "failed")]
        sh = self.write_result("robot.xml", junit(bad))
        acc, _ = self.load(self.record(status="FAIL", result_sha256=sh))
        self.assertEqual(self.row(acc)["status"], "FAIL")

    def test_no_iso_hash_or_wrong_format_accepts_nothing(self):
        acc, rej = self.load(self.record(), iso="")
        self.assertEqual((acc, bool(rej)), ({}, True))
        acc, rej = self.load(self.record(), doc_over={"format": "nope"})
        self.assertEqual((acc, bool(rej)), ({}, True))

    def test_summary_ignores_accepted_dict_without_iso_hash(self):
        acc, _ = self.load(self.record())
        rows = {r["item"]: r for r in mk.build_verification_summary("x.iso", None, acc)}
        self.assertEqual(rows["robot_81_cases"]["status"], "NOT_RUN")


BUILDINFO = """-----BEGIN PGP SIGNED MESSAGE-----
Format: 1.0
Source: vyatta-version
Binary: vyatta-version
Architecture: all
Version: 1.4
Checksums-Sha256:
 {} 100 vyatta-version_2608_all.deb
"""


class ProvenanceTest(SignedDirMixin, unittest.TestCase):
    COMMIT = "b" * 40
    ISO = sha(b"the iso bytes")

    def setUp(self):
        self.make_dir()
        self.bi = BUILDINFO.format("0" * 64).encode()
        (self.dir / "x.buildinfo").write_bytes(self.bi)

    def entry(self, **over):
        e = {"name": "vyatta-version", "version": "2608",
             "source_package": "vyatta-version", "source_version": "1.4",
             "commit": self.COMMIT, "buildinfo_file": "x.buildinfo",
             "buildinfo_sha256": sha(self.bi)}
        e.update(over)
        return e

    def load(self, *entries, iso=None, sign=True, key="k.pem", trusted=True, doc_over=None):
        doc = {"format": mk.PROVENANCE_FORMAT, "iso_sha256": self.ISO,
               "packages": list(entries)}
        doc.update(doc_over or {})
        path = self.write_signed("prov.json", doc, key=key, sign=sign)
        return mk.load_provenance(path, self.ISO if iso is None else iso,
                                  self.pub if trusted else None)

    def resolve(self, prov, installed="2608", recorded=(("1.4", "b" * 40),)):
        repo = {"vyatta-version": {"version": installed, "source": "vyatta-version"}}
        commits = {("vyatta-version", v): c for v, c in recorded}
        return mk.resolve_source("vyatta-version", installed, repo, commits, {},
                                 mk.index_commits_by_source(commits), prov)

    def test_signed_corroborated_provenance_is_a_claim_never_verified(self):
        prov, rej = self.load(self.entry())
        self.assertEqual(rej, [])
        r = self.resolve(prov)
        self.assertEqual(r["category"], "version_stamp_inferred")
        self.assertIs(r["verified"], False)
        self.assertNotIn("provenance", r)
        claim = r["provenance_claim"]
        self.assertEqual(claim["buildinfo_sha256"], sha(self.bi))
        self.assertEqual(len(claim["unproven_links"]), 2)

    def test_nothing_any_input_can_produce_a_verified_attribution(self):
        # signer-consistent, forged-consistent and mismatched inputs alike
        variants = [{}, {"commit": "d" * 40}, {"source_version": "1.5"},
                    {"source_package": "x"}, {"version": "2607"}]
        for over in variants:
            (self.dir / "x.buildinfo").write_bytes(self.bi)
            prov, _ = self.load(self.entry(**over))
            for recorded in ((("1.4", "b" * 40),), (("1.4", "d" * 40),), ()):
                r = self.resolve(prov, recorded=recorded)
                self.assertNotEqual(r["category"], "local_git_version_stamped", over)
                self.assertIsNot(r.get("verified"), True, over)

    def test_forged_but_self_consistent_record_is_still_not_verified(self):
        # attacker controls the signed doc AND a buildinfo they wrote to agree
        forged = BUILDINFO.format("f" * 64).replace("Version: 1.4", "Version: 1.4").encode()
        (self.dir / "x.buildinfo").write_bytes(forged)
        prov, rej = self.load(self.entry(buildinfo_sha256=sha(forged), commit="b" * 40))
        r = self.resolve(prov)
        self.assertIs(r["verified"], False)

    def test_no_provenance_stays_inferred(self):
        self.assertEqual(self.resolve(None)["category"], "version_stamp_inferred")

    def test_forged_buildinfo_naming_another_source_is_rejected(self):
        forged = self.bi.replace(b"Source: vyatta-version", b"Source: evil")
        (self.dir / "x.buildinfo").write_bytes(forged)
        prov, rej = self.load(self.entry(buildinfo_sha256=sha(forged)))
        self.assertEqual(prov, {})
        self.assertTrue(any("contradict" in r for _, r in rej))

    def test_forged_buildinfo_with_wrong_version_or_binary_is_rejected(self):
        for old, new in ((b"Version: 1.4", b"Version: 9.9"),
                         (b"Binary: vyatta-version", b"Binary: other-pkg")):
            forged = self.bi.replace(old, new)
            (self.dir / "x.buildinfo").write_bytes(forged)
            prov, rej = self.load(self.entry(buildinfo_sha256=sha(forged)))
            self.assertEqual(prov, {}, old)

    def test_self_declared_commit_without_signature_is_not_confirmed(self):
        prov, rej = self.load(self.entry(), sign=False)
        self.assertEqual(prov, {})
        self.assertEqual(self.resolve(prov)["category"], "version_stamp_inferred")

    def test_signature_by_untrusted_key_or_no_key_is_rejected(self):
        for kw in ({"key": "evil.pem"}, {"trusted": False}):
            prov, rej = self.load(self.entry(), **kw)
            self.assertEqual(prov, {}, kw)
            self.assertTrue(rej)

    def test_provenance_for_another_iso_is_rejected(self):
        prov, rej = self.load(self.entry(), doc_over={"iso_sha256": sha(b"other iso")})
        self.assertEqual(prov, {})
        self.assertTrue(any("iso_sha256" in r for _, r in rej))

    def test_tampered_buildinfo_missing_file_or_bad_commit_rejected(self):
        (self.dir / "x.buildinfo").write_bytes(self.bi + b"extra")
        for over in ({}, {"buildinfo_file": "none"}, {"commit": "abc"}):
            prov, _ = self.load(self.entry(**over))
            self.assertEqual(prov, {}, over)

    def test_signed_entry_for_a_different_commit_version_or_source_has_no_claim(self):
        for over in ({"commit": "d" * 40}, {"source_version": "1.5"},
                     {"source_package": "other-src"}, {"version": "2607"}):
            (self.dir / "x.buildinfo").write_bytes(self.bi)
            prov, _ = self.load(self.entry(**over))
            r = self.resolve(prov)
            self.assertNotEqual(r["category"], "local_git_version_stamped", over)
            self.assertNotIn("provenance_claim", r, over)

    def test_provenance_cannot_conjure_an_unrecorded_commit(self):
        prov, _ = self.load(self.entry())
        self.assertNotEqual(self.resolve(prov, recorded=())["category"],
                            "local_git_version_stamped")


class TrustedKeyPinTest(SignedDirMixin, unittest.TestCase):
    """A verifying signature is not enough: the public key itself must still be a
    root the project publishes (trusted-keys.sha256), otherwise a retired key can
    be fed back in and old signatures laundered through it."""

    def setUp(self):
        self.make_dir()

    def _verify_with_pin(self, allowlist_text):
        pin = self.keys / "trusted-keys.sha256"
        pin.write_text(allowlist_text)
        doc = self.write_signed("d.json", {"hello": "world"})
        real = mk.TRUSTED_KEYS_FILE
        mk.TRUSTED_KEYS_FILE = pin
        try:
            return mk.verify_signature(doc, self.pub)
        finally:
            mk.TRUSTED_KEYS_FILE = real

    def test_key_listed_in_allowlist_is_accepted(self):
        got = hashlib.sha256(self.pub.read_bytes()).hexdigest()
        ok, why = self._verify_with_pin(f"{got}  root-C\n")
        self.assertTrue(ok, why)

    def test_key_absent_from_allowlist_is_rejected(self):
        ok, why = self._verify_with_pin("deadbeef  root-A (lost)\n")
        self.assertFalse(ok)
        self.assertIn("not in release/trusted-keys.sha256", why)

    def test_empty_allowlist_rejects_everything(self):
        # An empty allowlist is still an allowlist: nothing matches, so nothing passes.
        ok, why = self._verify_with_pin("")
        self.assertFalse(ok)
        self.assertIn("not in release/trusted-keys.sha256", why)


# ---------------------------------------------------------------------------
# "verified" and the per-package provenance records.
# ---------------------------------------------------------------------------

STATUS = """Package: libc6
Status: install ok installed
Architecture: amd64
Source: glibc
Version: 2.41-12+deb13u4

Package: tzdata
Status: install ok installed
Architecture: all
Version: 2025b-5

Package: removed-thing
Status: deinstall ok config-files
Architecture: amd64
Version: 1.0

"""

PACKAGES = """Package: libc6
Version: 2.41-12+deb13u4
Architecture: amd64
Source: glibc
Filename: pool/main/g/glibc/libc6_2.41-12+deb13u4_amd64.deb
Size: 2846580
MD5sum: 5559581916477ef1f57ea9f82cecf22e
SHA256: 967aa62605721081c3eb2a17650611a792aa802d76a6511d1840242623d204c9
Description: GNU C Library
 more text that must not be mistaken for a field: Package: nope

Package: tzdata
Version: 2025b-5
Architecture: all
Filename: pool/main/t/tzdata/tzdata_2025b-5_all.deb
Size: 100
SHA256: aa

"""


def release_text(listed):
    lines = "".join(f" {h} 1 {path}\n" for path, h in listed.items())
    return "Origin: Debian\nSuite: stable\nSHA256:\n" + lines + "Acquire-By-Hash: yes\n"


def make_apt_tree(td, packages=PACKAGES, sign_ok=True, hash_ok=True):
    """A directory shaped like what read_image() extracts: var/lib/apt/lists + etc/apt/trusted.gpg.d."""
    lists = Path(td) / "var/lib/apt/lists"
    lists.mkdir(parents=True)
    (Path(td) / "etc/apt/trusted.gpg.d").mkdir(parents=True)
    pk = lists / "deb.debian.org_debian_dists_trixie_main_binary-amd64_Packages"
    pk.write_text(packages)
    want = hashlib.sha256(packages.encode()).hexdigest() if hash_ok else "0" * 64
    (lists / "deb.debian.org_debian_dists_trixie_InRelease").write_text(
        release_text({"main/binary-amd64/Packages": want}))
    return lambda inrelease, keys: (sign_ok, "fake gpgv" if sign_ok else "BADSIG deadbeef")


def rec(name, version, arch="amd64"):
    return {"name": name, "version": version, "arch": arch, "source": name}


class DpkgStatusTest(unittest.TestCase):
    def test_only_installed_packages_with_arch_and_source(self):
        got = mk.parse_dpkg_status(STATUS)
        self.assertEqual([(r["name"], r["version"], r["arch"], r["source"]) for r in got],
                         [("libc6", "2.41-12+deb13u4", "amd64", "glibc"), ("tzdata", "2025b-5", "all", "tzdata")])


class AptIndexTest(unittest.TestCase):
    def test_packages_index_keys_fields_and_ignores_continuation_lines(self):
        with tempfile.TemporaryDirectory() as td:
            f = Path(td) / "Packages"
            f.write_text(PACKAGES)
            idx = mk.parse_apt_packages(f)
        e = idx[("libc6", "2.41-12+deb13u4", "amd64")]
        self.assertEqual((e["sha256"], e["size"], e["source"]), (
            "967aa62605721081c3eb2a17650611a792aa802d76a6511d1840242623d204c9", 2846580, "glibc"))
        self.assertNotIn(("nope", "", ""), idx)
        self.assertIn(("tzdata", "2025b-5", "all"), idx)
        self.assertEqual(idx[("tzdata", "2025b-5", "all")]["md5"], "")

    def test_release_sha256_block(self):
        got = mk.release_sha256_entries(release_text({"main/binary-amd64/Packages": "ab", "main/Contents": "cd"}))
        self.assertEqual(got, {"main/binary-amd64/Packages": "ab", "main/Contents": "cd"})


class DebianVerifiedTest(unittest.TestCase):
    def load(self, **kw):
        td = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, td, True)
        verifier = make_apt_tree(td, **kw)
        return mk.load_apt_index(td, verifier=verifier)

    def test_listed_in_a_verified_index_is_verified_with_real_checksum(self):
        idx, rel = self.load()
        ok, why, prov = mk.debian_provenance(rec("libc6", "2.41-12+deb13u4"), idx, rel)
        self.assertTrue(ok, why)
        self.assertEqual(prov["deb_sha256"], "967aa62605721081c3eb2a17650611a792aa802d76a6511d1840242623d204c9")
        self.assertEqual(prov["deb_url"], "http://deb.debian.org/debian/pool/main/g/glibc/libc6_2.41-12+deb13u4_amd64.deb")
        self.assertEqual((prov["suite"], prov["component"], prov["upstream_source_package"]), ("trixie", "main", "glibc"))
        self.assertEqual(prov["unavailable"], {})

    def test_missing_md5_is_recorded_as_unavailable_not_invented(self):
        idx, rel = self.load()
        ok, _, prov = mk.debian_provenance(rec("tzdata", "2025b-5", "all"), idx, rel)
        self.assertTrue(ok)
        self.assertEqual(prov["deb_md5sum"], "")
        self.assertIn("deb_md5sum", prov["unavailable"])

    def test_bad_signature_is_not_verified_but_still_reports_the_checksum(self):
        idx, rel = self.load(sign_ok=False)
        ok, why, prov = mk.debian_provenance(rec("libc6", "2.41-12+deb13u4"), idx, rel)
        self.assertFalse(ok)
        self.assertIn("BADSIG", why)
        self.assertTrue(prov["deb_sha256"])

    def test_index_that_does_not_match_its_release_is_not_verified(self):
        idx, rel = self.load(hash_ok=False)
        ok, why, _ = mk.debian_provenance(rec("libc6", "2.41-12+deb13u4"), idx, rel)
        self.assertFalse(ok)
        self.assertIn("sha256", why)

    def test_version_or_arch_not_in_the_index_is_not_verified_and_says_why(self):
        idx, rel = self.load()
        for r in (rec("libc6", "2.41-12+deb13u3"), rec("libc6", "2.41-12+deb13u4", "arm64"), rec("ghost", "1")):
            ok, why, prov = mk.debian_provenance(r, idx, rel)
            self.assertFalse(ok)
            self.assertIn("not in any Packages index", why)
            self.assertIn("deb_sha256", prov["unavailable"])
            self.assertNotIn("deb_sha256", {k for k, v in prov.items() if v})


@unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgv"), "needs gpg and gpgv")
class InReleaseSignatureTest(unittest.TestCase):
    """verify_inrelease against a real throwaway key: accepts a good signature, rejects a tampered file and a stranger's key."""

    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.td, True)
        self.env = {**os.environ, "GNUPGHOME": str(self.td / "home")}
        (self.td / "home").mkdir(mode=0o700)
        subprocess.run(["gpg", "--batch", "--passphrase", "", "--quick-gen-key", "t@example.org", "default", "default", "never"],
                       env=self.env, capture_output=True, check=True)
        self.keys = self.td / "keys"
        self.keys.mkdir()
        pub = subprocess.run(["gpg", "--armor", "--export", "t@example.org"], env=self.env, capture_output=True, check=True).stdout
        (self.keys / "test.asc").write_bytes(pub)
        (self.td / "Release").write_text(release_text({"main/binary-amd64/Packages": "ab"}))
        subprocess.run(["gpg", "--batch", "--clearsign", "-o", str(self.td / "InRelease"), str(self.td / "Release")],
                       env=self.env, capture_output=True, check=True)

    def test_good_signature(self):
        ok, detail = mk.verify_inrelease(self.td / "InRelease", self.keys)
        self.assertTrue(ok, detail)

    def test_tampered_file_is_rejected(self):
        t = (self.td / "InRelease").read_text().replace("Origin: Debian", "Origin: Evil")
        (self.td / "InRelease").write_text(t)
        ok, detail = mk.verify_inrelease(self.td / "InRelease", self.keys)
        self.assertFalse(ok)
        self.assertIn("rejected", detail)

    def test_key_that_did_not_sign_is_rejected(self):
        other = self.td / "other"
        other.mkdir()
        env2 = {**os.environ, "GNUPGHOME": str(self.td / "home2")}
        (self.td / "home2").mkdir(mode=0o700)
        subprocess.run(["gpg", "--batch", "--passphrase", "", "--quick-gen-key", "o@example.org", "default", "default", "never"],
                       env=env2, capture_output=True, check=True)
        (other / "o.asc").write_bytes(subprocess.run(["gpg", "--armor", "--export", "o@example.org"], env=env2,
                                                      capture_output=True, check=True).stdout)
        ok, _ = mk.verify_inrelease(self.td / "InRelease", other)
        self.assertFalse(ok)

    def test_empty_keyring_dir_is_rejected_with_a_reason(self):
        empty = self.td / "empty"
        empty.mkdir()
        ok, detail = mk.verify_inrelease(self.td / "InRelease", empty)
        self.assertFalse(ok)
        self.assertIn("no archive keys", detail)


class LocalGitVerifiedTest(unittest.TestCase):
    """check_commit_published against real git repositories, one of them acting as the published remote."""

    def git(self, cwd, *a):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"}
        return subprocess.run(["git", "-C", str(cwd), *a], env=env, capture_output=True, text=True, check=True).stdout.strip()

    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.td, True)
        self.remote = self.td / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "master", str(self.remote)], check=True)
        self.work = self.td / "work"
        subprocess.run(["git", "init", "-q", "-b", "master", str(self.work)], check=True)
        self.git(self.work, "remote", "add", "i-danos", str(self.remote))
        (self.work / "a").write_text("1")
        self.git(self.work, "add", "a")
        self.git(self.work, "commit", "-qm", "one")
        self.c1 = self.git(self.work, "rev-parse", "HEAD")
        (self.work / "a").write_text("2")
        self.git(self.work, "commit", "-qam", "two")
        self.c2 = self.git(self.work, "rev-parse", "HEAD")
        self.git(self.work, "push", "-q", "i-danos", "master")

    def test_commit_in_published_history_is_verified(self):
        for c in (self.c1, self.c2):
            ok, why, info = mk.check_commit_published(self.work, c, {})
            self.assertTrue(ok, why)
            self.assertEqual(info["ref"], "refs/heads/master")

    def test_commit_only_on_a_local_branch_is_not_verified(self):
        self.git(self.work, "checkout", "-q", "-b", "local-only")
        (self.work / "a").write_text("3")
        self.git(self.work, "commit", "-qam", "three")
        c3 = self.git(self.work, "rev-parse", "HEAD")
        ok, why, _ = mk.check_commit_published(self.work, c3, {})
        self.assertFalse(ok)
        self.assertIn("not an ancestor", why)

    def test_commit_missing_from_the_clone_is_not_verified(self):
        ok, why, _ = mk.check_commit_published(self.work, "1" * 40, {})
        self.assertFalse(ok)
        self.assertIn("not in the local clone", why)

    def test_unreachable_remote_is_not_verified_and_says_so(self):
        self.git(self.work, "remote", "set-url", "i-danos", str(self.td / "nowhere.git"))
        ok, why, _ = mk.check_commit_published(self.work, self.c1, {})
        self.assertFalse(ok)
        self.assertIn("not reachable", why)

    def test_ls_remote_is_asked_once_per_remote(self):
        cache = {}
        mk.check_commit_published(self.work, self.c1, cache)
        shutil.rmtree(self.remote)
        ok, _, _ = mk.check_commit_published(self.work, self.c2, cache)
        self.assertTrue(ok)


class PublishedTagScanTest(unittest.TestCase):
    """check_commit_published against a repository whose published history is held by tags: how it asks, and what it says when it
    did not look at everything. Local git only; `mk.run` is wrapped to record every subprocess it starts."""

    def git(self, cwd, *a):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"}
        return subprocess.run(["git", "-C", str(cwd), *a], env=env, capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, name):
        (self.work / "f").write_text(name)
        self.git(self.work, "add", "f")
        self.git(self.work, "commit", "-qm", name)
        return self.git(self.work, "rev-parse", "HEAD")

    def setUp(self):
        self.td = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.td, True)
        self.remote = self.td / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "master", str(self.remote)], check=True)
        self.work = self.td / "work"
        subprocess.run(["git", "init", "-q", "-b", "master", str(self.work)], check=True)
        self.git(self.work, "remote", "add", "i-danos", str(self.remote))
        self.c1 = self.commit("one")
        self.c2 = self.commit("two")
        self.git(self.work, "push", "-q", "i-danos", "master")
        # a commit that only a tag holds: on a side branch that is never pushed, tag pushed
        self.git(self.work, "checkout", "-q", "-b", "side")
        self.side = self.commit("side")
        self.git(self.work, "tag", "v-side")
        self.git(self.work, "checkout", "-q", "master")
        # four more tags on published history so there are 5 tag tips in all
        for i in range(4):
            self.git(self.work, "tag", f"v{i}", self.c1 if i % 2 else self.c2)
        self.git(self.work, "push", "-q", "i-danos", "--tags")
        # a commit nothing published holds
        self.git(self.work, "checkout", "-q", "-b", "local-only")
        self.nowhere = self.commit("nowhere")
        self.git(self.work, "checkout", "-q", "master")

    def recorded(self, fn):
        calls, real = [], mk.run
        def rec(cmd, **kw):
            calls.append(list(cmd))
            return real(cmd, **kw)
        with mock.patch.object(mk, "run", side_effect=rec):
            out = fn()
        return out, calls

    @staticmethod
    def merge_bases(calls):
        return [c for c in calls if "merge-base" in c]

    def test_commit_on_a_branch_keeps_the_old_wording(self):
        ok, why, info = mk.check_commit_published(self.work, self.c1, {})
        self.assertTrue(ok, why)
        self.assertIn("ancestor of refs/heads/master", why)
        self.assertEqual(info["ref"], "refs/heads/master")

    def test_commit_only_on_a_tag_is_found_with_one_recheck(self):
        tag_sha = self.git(self.work, "rev-parse", "v-side")
        (ok, why, info), calls = self.recorded(lambda: mk.check_commit_published(self.work, self.side, {}))
        self.assertTrue(ok, why)
        self.assertIn("ancestor of refs/tags/v-side", why)
        self.assertEqual(info["ref"], "refs/tags/v-side")
        mb = self.merge_bases(calls)
        self.assertEqual([c for c in mb if c[-1] == tag_sha], [mb[-1]], "the tag is re-verified exactly once")
        self.assertEqual(len(mb), 2, "one for the single branch tip, one for the tag -- not one per tag: %s" % mb)
        self.assertTrue(any("for-each-ref" in c and "--contains=" + self.side in c for c in calls))

    def test_commit_in_no_tip_says_what_was_checked(self):
        (ok, why, _), calls = self.recorded(lambda: mk.check_commit_published(self.work, self.nowhere, {}))
        self.assertFalse(ok)
        self.assertIn("not an ancestor of any", why)
        self.assertIn("checked", why)
        self.assertIn("of 5 tag tips", why)
        self.assertEqual(len(self.merge_bases(calls)), 1, "only the branch tip is asked with merge-base: %s" % self.merge_bases(calls))

    def test_tags_this_clone_lacks_are_checked_one_by_one_up_to_the_limit(self):
        for t in self.git(self.work, "tag").split():
            self.git(self.work, "tag", "-d", t)
        ok, why, _ = mk.check_commit_published(self.work, self.nowhere, {}, tag_limit=2)
        self.assertFalse(ok)
        self.assertIn("checked 2 of 5 tag tips", why)
        self.assertIn("limit 2", why)
        self.assertNotIn("not an ancestor of any", why, "an incomplete look must not claim there is no such tip")

    def test_limit_does_not_stop_a_hit_that_is_within_it(self):
        for t in self.git(self.work, "tag").split():
            self.git(self.work, "tag", "-d", t)
        # the clone no longer has v-side, but the commit is still in it (branch side) and the remote tag points at it
        ok, why, _ = mk.check_commit_published(self.work, self.side, {}, tag_limit=50)
        self.assertTrue(ok, why)
        self.assertIn("refs/tags/v-side", why)

    def test_a_stale_local_tag_does_not_hide_the_remote_one(self):
        # the remote's v-side points at self.side; here the same name points somewhere else, so --contains cannot be trusted for it
        self.git(self.work, "tag", "-f", "v-side", self.c1)
        ok, why, info = mk.check_commit_published(self.work, self.side, {})
        self.assertTrue(ok, why)
        self.assertEqual(info["ref"], "refs/tags/v-side")

    def test_failed_one_pass_falls_back_to_a_capped_scan_and_says_so(self):
        real = mk.run
        def broken(cmd, **kw):
            if "for-each-ref" in cmd:
                return subprocess.CompletedProcess(cmd, 128, stdout="", stderr="fatal: boom")
            return real(cmd, **kw)
        with mock.patch.object(mk, "run", side_effect=broken):
            ok, why, _ = mk.check_commit_published(self.work, self.nowhere, {}, tag_limit=3)
        self.assertFalse(ok)
        self.assertIn("checked 3 of 5 tag tips", why)
        self.assertIn("for-each-ref failed", why)
        self.assertNotIn("not an ancestor of any", why)

    def test_timed_out_one_pass_falls_back_the_same_way(self):
        real = mk.run
        def slow(cmd, **kw):
            if "for-each-ref" in cmd:
                raise subprocess.TimeoutExpired(cmd, kw.get("timeout", 0))
            return real(cmd, **kw)
        with mock.patch.object(mk, "run", side_effect=slow):
            ok, why, _ = mk.check_commit_published(self.work, self.side, {}, tag_timeout=1, tag_limit=50)
        self.assertTrue(ok, why)                      # the capped scan still finds a commit that is within the cap
        with mock.patch.object(mk, "run", side_effect=slow):
            ok, why, _ = mk.check_commit_published(self.work, self.nowhere, {}, tag_timeout=1, tag_limit=2)
        self.assertFalse(ok)
        self.assertIn("checked 2 of 5 tag tips", why)
        self.assertIn("timed out", why)

    def test_unreachable_remote_keeps_its_wording(self):
        self.git(self.work, "remote", "set-url", "i-danos", str(self.td / "nowhere.git"))
        ok, why, _ = mk.check_commit_published(self.work, self.c1, {})
        self.assertFalse(ok)
        self.assertTrue(why.startswith("remote not reachable:"), why)

    def test_the_same_commit_is_not_worked_out_twice(self):
        cache = {}
        first = mk.check_commit_published(self.work, self.side, cache)
        out, calls = self.recorded(lambda: mk.check_commit_published(self.work, self.side, cache))
        self.assertEqual(calls, [])
        self.assertEqual(out, first)


class EnrichRowsTest(unittest.TestCase):
    def rows(self):
        return [
            {"name": "libc6", "version": "2.41-12+deb13u4", "category": "external_source", "source_package": "libc6",
             "reason": "not built by this project's OBS project in any form"},
            {"name": "mine", "version": "1.0", "category": "local_git", "source_package": "mine", "commit": "c" * 40},
            {"name": "mine-stamped", "version": "1.0danos1", "category": "version_stamp_inferred", "source_package": "mine",
             "commit": "c" * 40, "verified": False, "reason": "guess"},
            {"name": "inherited", "version": "1", "category": "signed_alias", "source_package": "inherited", "reason": "baseline"},
        ]

    def run_enrich(self, checker, remote_check=True):
        td = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, td, True)
        verifier = make_apt_tree(td)
        idx, rel = mk.load_apt_index(td, verifier=verifier)
        src = Path(td) / "src/mine/debian"
        src.mkdir(parents=True)
        (src / "control").write_text("Source: mine\n")
        rows = self.rows()
        prov = mk.enrich_rows(rows, [rec("libc6", "2.41-12+deb13u4")], idx, rel, Path(td) / "src",
                              remote_check=remote_check, checker=checker)
        return rows, prov

    def test_categories_are_untouched_and_every_row_gets_a_verdict_with_a_reason(self):
        rows, prov = self.run_enrich(lambda d, c, cache: (True, "published", {"ref": "refs/heads/master"}))
        self.assertEqual([r["category"] for r in rows], ["external_source", "local_git", "version_stamp_inferred", "signed_alias"])
        self.assertEqual([r["verified"] for r in rows], [True, True, False, False])
        for r in rows:
            self.assertTrue(r["verified_reason"])
        self.assertEqual({p["name"] for p in prov}, {"libc6", "mine"})

    def test_external_source_reason_is_replaced_by_the_conclusion_and_names_the_checksum(self):
        rows, _ = self.run_enrich(lambda *a: (True, "x", {}))
        self.assertNotEqual(rows[0]["reason"], "not built by this project's OBS project in any form")
        self.assertIn("967aa626", rows[0]["reason"])
        self.assertIn("Not built by", rows[0]["reason"])

    def test_remote_check_off_means_local_git_is_false_with_that_reason(self):
        rows, _ = self.run_enrich(lambda *a: self.fail("checker must not run"), remote_check=False)
        self.assertFalse(rows[1]["verified"])
        self.assertIn("--no-remote-check", rows[1]["verified_reason"])

    def test_failed_checker_result_is_carried_not_hidden(self):
        rows, prov = self.run_enrich(lambda d, c, cache: (False, "not an ancestor of any remote tip", {}))
        self.assertFalse(rows[1]["verified"])
        self.assertIn("not an ancestor", [p for p in prov if p["name"] == "mine"][0]["verified_reason"])

    def test_summary_counts_and_groups_the_false_reasons(self):
        rows, _ = self.run_enrich(lambda d, c, cache: (True, "published", {}))
        s = mk.verified_summary(rows)
        self.assertEqual((s["true"], s["false"]), (2, 2))
        self.assertEqual(s["by_category"]["external_source"], {"true": 1, "false": 0})
        self.assertEqual({r["category"] for r in s["false_reasons"]}, {"version_stamp_inferred", "signed_alias"})



if __name__ == "__main__":
    unittest.main()
