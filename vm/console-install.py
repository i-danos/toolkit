#!/usr/bin/env python3
"""Drive "install image" over a QEMU serial console.

console.py sends a command and waits for a shell prompt. The installer is not
that shape: it asks a series of questions, the set of which depends on the
answers, and there is no prompt to wait for in between. So this answers by
pattern rather than by position.

Position would be the obvious way to write it and is the wrong one. A fixed
list of answers stays aligned only while the questions do; skip one -- because
a disk is already partitioned, or a grub password is declined, or an ONIE
environment is detected -- and every later answer goes to the wrong question,
silently, with the installer proceeding on values nobody chose.

So each rule is (what the installer asked, what to answer), the log records
which rule fired for which prompt, and a prompt matching no rule is a failure
rather than something to guess at. An installer waiting on an unanswered
question looks exactly like one that has hung.

Usage:
    console-install.py <console.sock> [--password PW] [--timeout SECONDS]
"""

import argparse
import re
import socket
import sys
import time

ANSI = re.compile(rb"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[a-zA-Z]"
                  rb"|\x1b[()][B0]|[\x00-\x08\x0b\x0c\x0e-\x1f]")

# Ordered: the first match wins, so put the specific before the general.
# "" means press Enter and take the installer's own default.
def rules(admin_user, admin_password):
    return [
        # Destructive confirmations. Answered Yes deliberately -- the only disk
        # attached is the throwaway qcow2 the caller created.
        (rb"[Ww]ould you like to continue\?",                    "Yes"),
        # "Continue (Yes/No) [No]:" -- no question mark, and the default is
        # No. The generic "accept the default" rule below is right for every
        # size prompt and catastrophic for this one: answering it with a bare
        # newline declines the install, the installer exits cleanly to a shell,
        # and the disk is never written. That is what happened, and it was
        # reported as the installer getting stuck rather than as it being told
        # to stop.
        # Anchored on the *end* of the prompt, not on its beginning.
        #
        # The first version matched as soon as "Continue" arrived, while
        # "(Yes/No) [No]: " was still in flight. The answer went out before
        # anything was reading, was discarded, and when the rest of the prompt
        # landed the generic default rule answered it with a bare newline --
        # which is No, so the installer exited. The console showed "Yes"
        # echoed and then a shell prompt, which read like the installer
        # ignoring a correct answer.
        #
        # Requiring the trailing "[No]: " means the prompt is complete and
        # something is waiting for the line.
        (rb"Continue \(Yes/No\) \[[^\]]*\]:\s*$",                "Yes"),
        (rb"Continue\?",                                           "Yes"),
        (rb"partition.*\(Auto\|Parted\|Skip\)",                  ""),
        (rb"[Ww]ould you like me to try to partition",            "Yes"),
        (rb"[Ii]nstall the image on\b",                          ""),
        (rb"This will destroy all data",                          "Yes"),
        (rb"[Ee]rase.*\?",                                        "Yes"),

        # The account the installer creates on the installed system. This is
        # not the account used to log in to the live system to start the
        # install -- those are tmpuser/tmppwd and they do not exist afterwards.
        # An earlier version passed one password for both, so the installed
        # system's account ended up with the live system's password.
        (rb"Enter (the )?(login|admin|username)",                 admin_user),
        (rb"[Ee]nter password for",                               admin_password),
        (rb"[Rr]etype password for",                              admin_password),
        (rb"[Pp]assword:\s*$",                                    admin_password),

        # Declined: a grub password would have to be supplied again at every
        # boot, and nothing here can type it.
        (rb"grub password",                                       "No"),
        (rb"[Ee]nable.*GRUB",                                     "No"),

        # Defaults are correct for a serial-console VM.
        (rb"console type",                                        ""),
        (rb"[Ss]peed",                                            ""),
        (rb"[Ii]mage name",                                       ""),
        (rb"[Ww]hich partition",                                  ""),
        (rb"copy.*config",                                        "Yes"),
        (rb"save.*config",                                        "Yes"),

        # A bare default prompt: "[Yes]:" or "[/dev/vda]:".
        (rb"\[[^\]]*\]:\s*$",                                     ""),
    ]


DONE = re.compile(rb"Done\b|Installation (finished|complete|succeeded)"
                  rb"|Rebooting|reboot now", re.I)
FAIL = re.compile(rb"fail_exit|Unable to |No such device|Exiting", re.I)
PROMPT = re.compile(rb"[$#] ?$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock")
    ap.add_argument("--password", default="vyatta")
    ap.add_argument("--user", default="vyatta")
    ap.add_argument("--admin-user", default="vyatta")
    ap.add_argument("--admin-password", default="vyatta")
    ap.add_argument("--timeout", type=int, default=1200)
    a = ap.parse_args()

    table = rules(a.admin_user, a.admin_password)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(a.sock)

    buf = b""
    answered = 0
    last_answer_at = time.time()
    deadline = time.time() + a.timeout
    started = False
    logged_out = False

    def send(text):
        s.sendall(text.encode() + b"\r")

    # Wake the console and log in, then start the installer. The live image's
    # account is known; it is the installed system's that is not, which is the
    # whole reason this runs the interactive installer at all.
    send("")
    time.sleep(2)

    while time.time() < deadline:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            chunk = b""
        except OSError:
            break
        if chunk:
            buf += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.flush()

        clean = ANSI.sub(b"", buf)
        tail = clean[-400:]

        if not started:
            # Log out of whatever session is already on the console before
            # doing anything else. The console is shared: an earlier step in
            # the acceptance run leaves a tmpuser session sitting at a prompt,
            # and without this the installer was typed into *that* -- the
            # sandboxed account with no block devices, which is the whole
            # thing the superuser account exists to avoid. The prompt in the
            # log said tmpuser@node while --user said otherwise.
            if not logged_out:
                if PROMPT.search(clean.split(b"\n")[-1].rstrip(b"\r")):
                    send("exit")
                    logged_out = True
                    buf = b""
                    time.sleep(2)
                    continue
                if re.search(rb"login:\s*$", clean[-80:]):
                    logged_out = True   # already at a login prompt
                else:
                    if not chunk:
                        send("")
                    continue
            if re.search(rb"login:\s*$", clean[-80:]):
                send(a.user); buf = b""; continue
            if re.search(rb"[Pp]assword:\s*$", clean[-80:]):
                send(a.password); buf = b""; continue
            if PROMPT.search(clean.split(b"\n")[-1].rstrip(b"\r")):
                send("install image")
                started = True
                last_answer_at = time.time()
                buf = b""
                continue
            if not chunk:
                send("")
            continue

        if DONE.search(tail):
            print("\n*** installer reported completion", file=sys.stderr)
            return 0
        if FAIL.search(tail):
            print(f"\n*** installer failed: {tail[-200:]!r}", file=sys.stderr)
            return 2

        for pat, answer in table:
            if re.search(pat, tail):
                send(answer)
                answered += 1
                last_answer_at = time.time()
                print(f"\n[answered {pat.decode(errors='replace')!r} "
                      f"-> {answer!r}]", file=sys.stderr)
                buf = b""
                break
        else:
            # Nothing matched. If the installer has gone quiet while waiting,
            # that is an unanswered question, and guessing at it is how a fixed
            # sequence goes wrong. Say so instead.
            if time.time() - last_answer_at > 180:
                print(f"\n*** stuck: no rule matched and nothing has moved "
                      f"for 180s. Last output:\n{tail.decode(errors='replace')}",
                      file=sys.stderr)
                return 3
            if not chunk:
                time.sleep(1)

    print(f"\n*** timed out after {a.timeout}s, {answered} prompts answered",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
