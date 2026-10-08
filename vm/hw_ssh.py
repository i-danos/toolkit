# SPDX-License-Identifier: LGPL-2.1-only
"""SSH helpers for the physical DANOS bench: reach a router directly or through R1.

The bench has one wired NIC on the test host, so every router except the one cabled to it is
reached by opening an SSH channel *through* R1 (paramiko direct-tcpip) rather than by routing from
the host. That keeps management traffic off the links under test where possible.

The accounts here are sandboxed (no `show`, `ip`, `sudo` in a non-interactive exec). Operational and
configuration commands therefore need an interactive shell, which `cli()` drives; plain Linux
commands go through `run()`, and root commands through `sudo()` with the account's password on stdin.
Configuration mode state does not survive between `cli()` calls: send `configure ... commit ... exit`
in one call.
"""
import re
import time

import paramiko

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07")
GATEWAY = "192.168.71.2"
USER = PASSWORD = "admin"


def connect(target, gateway=GATEWAY):
    """Return (gateway_client, target_client); both are the same when target is the gateway."""
    j = paramiko.SSHClient()
    j.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    j.connect(gateway, username=USER, password=PASSWORD, timeout=15,
              look_for_keys=False, allow_agent=False)
    if target == gateway:
        return j, j
    ch = j.get_transport().open_channel("direct-tcpip", (target, 22), ("127.0.0.1", 0))
    r = paramiko.SSHClient()
    r.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    r.connect(target, username=USER, password=PASSWORD, sock=ch, timeout=15,
              look_for_keys=False, allow_agent=False)
    return j, r


def run(r, cmd, timeout=40):
    _, o, e = r.exec_command(cmd, timeout=timeout)
    return (o.read() + e.read()).decode().strip()


def sudo(r, cmd, timeout=40):
    return run(r, "echo %s | sudo -S -p '' %s" % (PASSWORD, cmd), timeout)


def vtysh(r, *cmds):
    return sudo(r, "vtysh " + " ".join("-c '%s'" % c for c in cmds))


def cli(r, cmds, wait=3, commit_wait=60):
    """Type commands into one interactive shell; `commit` waits for the config prompt."""
    sh = r.invoke_shell(width=200)
    time.sleep(1.5)
    sh.recv(65535)
    out = ""
    for c in cmds:
        sh.send(c + "\n")
        t = commit_wait if c == "commit" else wait
        end = time.time() + t
        buf = ""
        while time.time() < end:
            if sh.recv_ready():
                buf += sh.recv(65535).decode("latin1")
            else:
                time.sleep(0.2)
            if c == "commit" and re.search(r"# $", ANSI.sub("", buf).replace("\r", "")) \
                    and len(buf) > len(c) + 5:
                break
        out += ANSI.sub("", buf)
    return out


def conf(r, cmds, commit_wait=150):
    """Configure + commit + save in a single shell; return any error lines."""
    o = cli(r, ["configure"] + cmds + ["commit", "save", "exit"], wait=2, commit_wait=commit_wait)
    return [l.strip() for l in o.split("\n")
            if any(k in l for k in ("Invalid", "rror", "failed", "not valid"))]
