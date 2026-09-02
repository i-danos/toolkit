#!/usr/bin/env python3
r"""Convert Robot Framework 3.x :FOR loops to the modern FOR/END form.

Robot Framework 4 deprecated the old syntax and 5 removed it, so on 7.x every
one of these fails the suite outright:

    Support for the old FOR loop syntax has been removed. Replace ':FOR' with
    'FOR', end the loop with 'END', and remove escaping backslashes.

Old:                                 New:
    :FOR  ${x}  IN  a  b                 FOR  ${x}  IN  a  b
    \    Keyword  ${x}                       Keyword  ${x}
    \    Other                               Other
    Next Keyword                         END
                                         Next Keyword

The loop body is whatever follows marked with a leading backslash cell; the
first line without one ends the loop, which is where END goes. Indentation of
the body is preserved so the diff stays readable.

Usage: modernize-for-loops.py <file> [<file>...]     (rewrites in place)
       modernize-for-loops.py --check <file>...      (report only)
"""

import re
import sys

FOR_RE = re.compile(r"^(\s*):FOR(\s+.*)$")
CONT_RE = re.compile(r"^(\s*)\\(\s+)(.*)$")


def convert(lines):
    out, changed = [], 0
    i = 0
    while i < len(lines):
        m = FOR_RE.match(lines[i])
        if not m:
            out.append(lines[i]); i += 1; continue

        indent, rest = m.group(1), m.group(2)
        out.append(f"{indent}FOR{rest}")
        changed += 1
        i += 1

        body_indent = None
        while i < len(lines):
            c = CONT_RE.match(lines[i])
            if not c:
                # A comment or blank line inside the body does not end the loop.
                # Treating it as the end drops END in the middle and leaves the
                # rest of the body as stray "\" lines, which Robot then reports
                # as: No keyword with name '\' found.
                if re.match(r"^\s*(#|$)", lines[i]) and any(
                        CONT_RE.match(l) for l in lines[i + 1:i + 6]):
                    out.append(lines[i])
                    i += 1
                    continue
                break
            # "\    Keyword" -> "    Keyword", one level in from the FOR
            if body_indent is None:
                body_indent = c.group(1) + "    "
            out.append(f"{body_indent}{c.group(3)}")
            i += 1
        out.append(f"{indent}END")
    return out, changed


def main():
    args = sys.argv[1:]
    check = args and args[0] == "--check"
    if check:
        args = args[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    total = 0
    for path in args:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        new, n = convert(lines)
        total += n
        if n:
            print(f"  {path}: {n} loop(s)")
            if not check:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(new))
    print(f"  {total} loop(s) {'found' if check else 'converted'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
