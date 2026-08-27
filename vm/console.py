#!/usr/bin/env python3
"""Drive a QEMU serial console over its unix socket.

The console is the only way in before SSH is configured. Driving it through the
QEMU monitor's sendkey loses backslashes and mangles shift combinations, which
has silently corrupted commands before; talking to the serial socket directly
gives a real byte stream instead.

Usage: console.py <console.sock> <user> <password> <command> [<command>...]
       console.py <console.sock> --raw            # just dump what is there
"""

import re
import socket
import sys
import time

PROMPT = re.compile(rb"[$#] ?$")
LOGIN = re.compile(rb"login: ?$")
PASSWORD = re.compile(rb"[Pp]assword: ?$")
BAD = re.compile(rb"[Ll]ogin incorrect")

# Strip ANSI/OSC so the prompt regexes match what a human sees.
ANSI = re.compile(rb"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][B0]|[\x00-\x08\x0b\x0c\x0e-\x1f]")


class Console:
    def __init__(self, path, timeout=120):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(2)
        self.s.connect(path)
        self.timeout = timeout
        self.buf = b""
        self.transcript = b""

    def read_until(self, pattern, timeout=None):
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                chunk = b""
            except OSError:
                break
            if chunk:
                self.buf += chunk
                self.transcript += chunk
            clean = ANSI.sub(b"", self.buf)
            for line in clean.split(b"\n")[-3:]:
                if BAD.search(line):
                    raise RuntimeError("login incorrect")
                if pattern.search(line.rstrip(b"\r")):
                    self.buf = b""
                    return clean
            if not chunk:
                self.send("")           # nudge a quiet console
        raise TimeoutError(f"timed out waiting for {pattern.pattern!r}")

    def send(self, text):
        self.s.sendall(text.encode() + b"\r")

    def login(self, user, password):
        """Log in, or do nothing if a shell session is already open.

        A previous run leaves the console logged in. Waiting unconditionally for
        "login:" then just nudges an already-live shell over and over, printing
        a wall of prompts and no output.
        """
        # Probe with a bare CR, never a command: at a login prompt anything else
        # is consumed as the username, which eats the prompt and leaves the
        # console at "Password:" where no later match can recover.
        self.send("")
        deadline = time.time() + 30
        state = None
        while time.time() < deadline and state is None:
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                chunk = b""
            except OSError:
                break
            if chunk:
                self.buf += chunk
                self.transcript += chunk
            last = ANSI.sub(b"", self.buf).split(b"\n")[-1].rstrip(b"\r")
            if LOGIN.search(last):
                state = "login"
            elif PASSWORD.search(last):
                # A previous run left the prompt mid-login; finish it.
                state = "password"
            elif PROMPT.search(last):
                state = "shell"
            elif not chunk:
                self.send("")

        if state == "shell":
            self.buf = b""
            return
        if state == "login":
            self.buf = b""
            self.send(user)
            self.read_until(PASSWORD)
        self.buf = b""
        self.send(password)
        self.read_until(PROMPT)

    def run(self, cmd):
        """Run one command and return its output.

        Matching on the shell prompt alone reads one command behind: the
        terminal echoes the command on a line that itself ends in "$ ", so the
        prompt regex fires on the echo rather than on the prompt that follows
        the output. Bracketing with a sentinel removes the ambiguity -- nothing
        else on the wire looks like it.
        """
        marker = "__CONSOLE_DONE__"
        # Never send "?" to this console. The vyatta CLI shell binds it to
        # completion/help, so it is swallowed and answered with a bell: writing
        # "echo M$?" arrives as "echo M$" + BEL and prints a literal "M$".
        # ${PIPESTATUS[0]} is the same value with no "?" in it.
        self.send(f"{cmd}; echo {marker}${{PIPESTATUS[0]}}")
        pattern = re.compile(marker.encode() + rb"(\d+)")
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            clean = ANSI.sub(b"", self.buf)
            # Only the command's OUTPUT can match: the echo, if the tty echoes
            # at all, carries a literal "$?" rather than digits. Counting
            # occurrences instead would hang whenever echo is off.
            m = pattern.search(clean)
            if m:
                text = clean[: m.start()].decode("utf-8", "replace")
                self.buf = clean[m.end():]
                lines = [l.rstrip("\r") for l in text.split("\n")]
                # Drop the echoed command line itself.
                if lines and marker in lines[0]:
                    lines = lines[1:]
                self.rc = int(m.group(1))
                return "\n".join(lines).strip("\n")
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                chunk = b""
            except OSError:
                break
            if chunk:
                self.buf += chunk
                self.transcript += chunk
        raise TimeoutError(f"timed out running {cmd!r}")


def main():
    path = sys.argv[1]
    c = Console(path)
    if sys.argv[2] == "--raw":
        time.sleep(3)
        try:
            c.read_until(re.compile(rb"\Z\A"), timeout=5)
        except (TimeoutError, RuntimeError):
            pass
        sys.stdout.write(ANSI.sub(b"", c.transcript).decode("utf-8", "replace"))
        return 0

    user, password, cmds = sys.argv[2], sys.argv[3], sys.argv[4:]
    try:
        c.login(user, password)
    except Exception as e:                                  # noqa: BLE001
        print(f"*** LOGIN FAILED: {e}", file=sys.stderr)
        tail = ANSI.sub(b"", c.transcript).decode("utf-8", "replace")
        print(tail[-1500:], file=sys.stderr)
        return 1

    rc = 0
    for cmd in cmds:
        print(f"$ {cmd}")
        try:
            print(c.run(cmd))
        except Exception as e:                              # noqa: BLE001
            print(f"*** {e}", file=sys.stderr)
            rc = 1
            break
    return rc


if __name__ == "__main__":
    sys.exit(main())
