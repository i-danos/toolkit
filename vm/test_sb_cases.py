"""Tests for the Secure Boot acceptance cases (cases/sb-*.yaml), without a VM.

verify-secure-boot.sh is replaced by a fake that leaves results.txt, serial logs, the certificate and a log
exactly as the real one does; the cases must pass on a good run and fail, each on its own step, when the
classification or the evidence is wrong, and must not be satisfied by files left by an earlier run.

Run: python3 -m unittest -v vm/test_sb_cases.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "verify-case.py"
CASES = HERE / "cases"

LIVE = "signed_boot_chain_live_iso"
EXPIRY = "signed_boot_chain_certificate_expiry"
# handoff/verify/suite-config.json required_cases (the contract), classname = item key
REQUIRED = {
    LIVE: ["t1-unenrolled-chain-is-refused-by-shim", "t2-chain-with-the-obs-mok-boots-the-kernel",
           "t3-one-flipped-bit-in-grub-is-refused", "t4-one-flipped-bit-in-the-kernel-is-refused"],
    EXPIRY: ["guest-clock-past-the-cert-expiry-still-boots"],
}

GOOD = {"T1": "shim-refused", "T2": "kernel-started", "T3": "shim-refused",
        "T4": "grub-refused-kernel(bad shim signature)"}
SERIAL = {"T1": "Verification failed: (0x1A) Security Violation", "T2": "[    0.000000] Linux version 6.12.0",
          "T3": "Verification failed: (0x1A) Security Violation", "T4": "error: bad shim signature"}

FAKE = r"""#!/bin/bash
# fake verify-secure-boot.sh <iso> <out> <vfv>: the files the real one leaves, from $FAKE_* variables
OUT=$2
mkdir -p "$OUT/inspect"
echo "  qemu: -enable-kvm -cpu host -smp 2 -m 3072 ${FAKE_RTC:-(guest clock: host)} -machine q35,smm=on, OVMF secboot" > "$OUT/secure-boot.log"
cp "$FAKE_CERT" "$OUT/inspect/grubx64.signer.pem"
: > "$OUT/results.txt"
for t in ${FAKE_ONLY//,/ }; do
  tok=$(printenv "FAKE_$t"); [ -n "$tok" ] || tok=nothing-recognised
  echo "$t $tok" >> "$OUT/results.txt"
  printenv "FAKE_SERIAL_$t" > "$OUT/$(echo $t | tr A-Z a-z).serial"
done
[ -n "${FAKE_DUP:-}" ] && echo "T1 shim-refused" >> "$OUT/results.txt"
exit 0
"""


def make_cert(d, days):
    key, crt = Path(d, "k.pem"), Path(d, "c.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(crt),
                    "-days", str(days), "-subj", "/CN=fake obs"], check=True, capture_output=True)
    return crt


def junit(path):
    return {tc.get("name"): ("FAIL" if tc.find("failure") is not None else "SKIP" if tc.find("skipped") is not None
                             else "PASS") for tc in ET.parse(path).getroot().iter("testcase")}, \
        {tc.get("classname") for tc in ET.parse(path).getroot().iter("testcase")}


def step_output(path, name):
    for tc in ET.parse(path).getroot().iter("testcase"):
        if tc.get("name") == name:
            so = tc.find("system-out")
            return so.text if so is not None else (tc.find("failure").text if tc.find("failure") is not None else "")
    return ""


class Run:
    def __init__(self, case, **fake):
        self.td = tempfile.TemporaryDirectory()
        self.d = Path(self.td.name)
        (self.d / "vm").mkdir()
        fv = self.d / "vm" / "verify-secure-boot.sh"
        fv.write_text(FAKE)
        fv.chmod(0o755)
        self.out = self.d / "secure-boot-x"
        self.case = CASES / case
        self.cert = make_cert(self.d, fake.pop("cert_days", 365))
        self.env = dict(os.environ, FAKE_CERT=str(self.cert), **{k: v for k, v in fake.items()})

    def run(self):
        iso = self.d / "x.iso"
        iso.write_bytes(b"iso")
        self.out.mkdir(exist_ok=True)
        j = self.out / "j.xml"
        p = subprocess.run([sys.executable, str(TOOL), str(self.case), "--exec", "local", "--junit", str(j), "--allow-dirty",
                            "--var", f"out={self.out}", "--var", f"iso={iso}", "--var", f"vm_dir={self.d / 'vm'}"],
                           capture_output=True, text=True, env=self.env, timeout=300)
        self.junit = j
        return p, (junit(j) if j.exists() else ({}, set()))

    def close(self):
        self.td.cleanup()


class LiveIso(unittest.TestCase):
    def run_case(self, **over):
        env = {"FAKE_T1": GOOD["T1"], "FAKE_T2": GOOD["T2"], "FAKE_T3": GOOD["T3"], "FAKE_T4": GOOD["T4"],
               **{f"FAKE_SERIAL_{t}": s for t, s in SERIAL.items()}, "FAKE_ONLY": "T1,T2,T3,T4"}
        env.update(over)
        r = Run("sb-live-iso.yaml", **env)
        self.addCleanup(r.close)
        return r.run()

    def test_the_required_names_and_the_classname_are_the_contract(self):
        case = json.loads((CASES / "sb-live-iso.yaml").read_text())
        self.assertEqual(case["id"], LIVE)
        names = [s["name"] for s in case["steps"]]
        for n in REQUIRED[LIVE]:
            self.assertIn(n, names)

    def test_a_good_run_passes_all_four_and_the_classname_is_the_item_key(self):
        p, (res, classes) = self.run_case()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for n in REQUIRED[LIVE]:
            self.assertEqual(res[n], "PASS", n)
        self.assertEqual(classes, {LIVE})

    def test_each_test_fails_on_its_own_wrong_classification(self):
        for t, slug in zip(("T1", "T2", "T3", "T4"), REQUIRED[LIVE]):
            for bad in ("kernel-started" if t != "T2" else "shim-refused", "chain-stopped-after-shim(no GRUB, no kernel)"):
                p, (res, _) = self.run_case(**{f"FAKE_{t}": bad})
                self.assertEqual(res[slug], "FAIL", (t, bad))
                self.assertEqual([res[s] for s in REQUIRED[LIVE] if s != slug], ["PASS"] * 3, (t, bad))
                self.assertEqual(p.returncode, 1)

    def test_t4_needs_the_bad_shim_signature_message_not_just_any_refusal(self):
        p, (res, _) = self.run_case(FAKE_T4="shim-refused")
        self.assertEqual(res[REQUIRED[LIVE][3]], "FAIL")

    def test_a_result_printed_twice_does_not_pass(self):
        p, (res, _) = self.run_case(FAKE_DUP="1")
        self.assertEqual(res[REQUIRED[LIVE][0]], "FAIL")

    def test_a_missing_result_fails_its_step(self):
        p, (res, _) = self.run_case(FAKE_T3="")
        self.assertEqual(res[REQUIRED[LIVE][2]], "FAIL")
        p, (res, _) = self.run_case(FAKE_ONLY="T1,T2")
        self.assertEqual(res["run-secure-boot-fixture"], "FAIL")      # RESULT_LINES must be 4

    def test_stale_results_from_an_earlier_run_cannot_satisfy_it(self):
        r = Run("sb-live-iso.yaml", FAKE_ONLY="")
        self.addCleanup(r.close)
        r.out.mkdir()
        (r.out / "results.txt").write_text("".join(f"{t} {tok}\n" for t, tok in GOOD.items()))
        p, (res, _) = r.run()
        for n in REQUIRED[LIVE]:
            self.assertEqual(res[n], "FAIL", n)

    def test_the_run_step_reports_the_qemu_cpu_and_accel_it_used(self):
        r = Run("sb-live-iso.yaml", FAKE_ONLY="T1", FAKE_T1=GOOD["T1"], FAKE_SERIAL_T1=SERIAL["T1"], FAKE_RTC="-rtc base=2030-01-01")
        self.addCleanup(r.close)
        r.run()
        self.assertIn("qemu:   qemu: -enable-kvm -cpu host", step_output(r.junit, "run-secure-boot-fixture"))

    def test_it_refuses_to_empty_a_directory_that_is_not_secure_boot(self):
        r = Run("sb-live-iso.yaml", FAKE_ONLY="T1")
        self.addCleanup(r.close)
        r.out = r.d / "precious"
        r.out.mkdir()
        (r.out / "keep").write_text("x")
        p, (res, _) = r.run()
        self.assertTrue((r.out / "keep").exists())
        self.assertEqual(res["run-secure-boot-fixture"], "FAIL")


class CertExpiry(unittest.TestCase):
    CLOCK = "[    1.252801] rtc_cmos 00:04: setting system clock to 2030-01-01T00:00:10 UTC (1893456010)"

    def run_case(self, serial=None, cert_days=365, **over):
        s = serial if serial is not None else "[    0.015] Secure boot enabled\n" + self.CLOCK
        env = {"FAKE_T2": GOOD["T2"], "FAKE_SERIAL_T2": s, "FAKE_ONLY": "T2", "cert_days": cert_days}
        env.update(over)
        r = Run("sb-cert-expiry.yaml", **env)
        self.addCleanup(r.close)
        return r.run()

    def test_the_name_is_the_contract(self):
        case = json.loads((CASES / "sb-cert-expiry.yaml").read_text())
        self.assertEqual(case["id"], EXPIRY)
        self.assertIn(REQUIRED[EXPIRY][0], [s["name"] for s in case["steps"]])

    def test_a_clock_after_the_certificate_end_with_secure_boot_enabled_passes(self):
        p, (res, classes) = self.run_case()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(res[REQUIRED[EXPIRY][0]], "PASS")
        self.assertEqual(classes, {EXPIRY})

    def test_a_clock_before_the_certificate_end_does_not_pass(self):
        p, (res, _) = self.run_case(cert_days=365 * 10)                  # the certificate outlives 2030
        self.assertEqual(res[REQUIRED[EXPIRY][0]], "FAIL")

    def test_no_clock_line_does_not_pass(self):
        p, (res, _) = self.run_case(serial="[    0.015] Secure boot enabled")
        self.assertEqual(res[REQUIRED[EXPIRY][0]], "FAIL")

    def test_secure_boot_not_reported_does_not_pass(self):
        p, (res, _) = self.run_case(serial=self.CLOCK)
        self.assertEqual(res[REQUIRED[EXPIRY][0]], "FAIL")

    def test_the_kernel_not_starting_does_not_pass(self):
        p, (res, _) = self.run_case(FAKE_T2="shim-refused")
        self.assertEqual(res[REQUIRED[EXPIRY][0]], "FAIL")


if __name__ == "__main__":
    unittest.main()
