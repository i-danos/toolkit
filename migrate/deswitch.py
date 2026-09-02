#!/usr/bin/env python3
"""Rewrite Perl given/when (smartmatch) as if/elsif/else.

Perl deprecated the switch feature in 5.38 and removed it in 5.42. Debian 13
ships 5.40, where it still runs but prints a deprecation warning per construct
-- **on stdout**, which is what makes this urgent rather than cosmetic: the
warnings land in the middle of op-mode command output, so

    show vpn ipsec sa

returns a wall of "given is deprecated at .../Util.pm line 375." instead of the
SA table, and anything parsing that output sees nothing it recognises.

The translation keeps the enclosing block, which is what preserves behaviour:
"for (EXPR)" already sets $_, and "given (EXPR)" becomes "for (EXPR)" -- the
same topicaliser without the removed feature.

Chaining is where this gets subtle, and getting it wrong is silent:

  * A when block that ends with "continue" means *fall through* -- carry on and
    test the next condition too. That becomes a standalone "if", and the
    "continue" is dropped: an independent if is tested regardless of whether
    the previous one ran, which is exactly what fall-through does.

  * A when block without "continue" carries an implicit break. Those must chain
    as if/elsif, or a later condition would start running when the original
    would have left the block.

So the rule is: emit "if" to open a chain, "elsif" to continue one, and end the
chain after any block that fell through. Treating every block as a standalone
"if" gets the continue case right and every other case wrong -- the package's
own test suite catches it as

    Can't "continue" outside a when block at .../Charon.pm line 306.

Smartmatch itself is replaced by what it actually did for these operands: a
regex stays a match against $_, a string becomes eq, a number ==, and
"when (undef)" becomes !defined.

Usage: deswitch.py <file.pm>...      (rewrites in place)
"""

import re
import sys

GIVEN = re.compile(r"^(\s*)given(\s*\()")
WHEN_BLOCK = re.compile(r"^(\s*)when\s*\((.*)\)\s*\{\s*$")
WHEN_STMT = re.compile(r"^(\s*)(.*\S)\s+when\s*\((.*)\)\s*;\s*$")
DEFAULT = re.compile(r"^(\s*)default(\s*\{.*)$")
CONTINUE = re.compile(r"^\s*continue\s*;\s*$")
CLOSE = re.compile(r"^\s*\}\s*$")


def cond(expr):
    """What smartmatch against $_ meant for this operand."""
    e = expr.strip()
    if e.startswith("/") or e.startswith("m/") or e.startswith("qr"):
        return e                          # regex: $_ =~ // is the default
    if e == "undef":
        return "!defined($_)"
    if re.fullmatch(r"-?\d+(\.\d+)?", e):
        return f"$_ == {e}"
    return f"$_ eq {e}"


def block_end(lines, start):
    """Index of the line closing the block that opens on `start`."""
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            return i
    return len(lines) - 1


def convert(lines):
    out, changed = [], 0
    open_chain = False                    # is an if/elsif chain currently open?
    i = 0

    while i < len(lines):
        line = lines[i]

        m = GIVEN.match(line)
        if m:
            out.append(GIVEN.sub(r"\1for\2", line))
            open_chain = False
            changed += 1
            i += 1
            continue

        m = WHEN_BLOCK.match(line)
        if m:
            indent, expr = m.group(1), m.group(2)
            end = block_end(lines, i)
            body = lines[i + 1:end]
            falls_through = any(CONTINUE.match(b) for b in body)

            kw = "elsif" if open_chain else "if"
            out.append(f"{indent}{kw} ({cond(expr)}) {{")
            out.extend(b for b in body if not CONTINUE.match(b))
            out.append(lines[end])
            changed += 1

            # Falling through ends the chain: the next condition has to be
            # tested on its own, not as an elsif of this one.
            open_chain = not falls_through
            i = end + 1
            continue

        m = WHEN_STMT.match(line)
        if m:
            indent, stmt, expr = m.group(1), m.group(2), m.group(3)
            kw = "elsif" if open_chain else "if"
            out.append(f"{indent}{kw} ({cond(expr)}) {{ {stmt}; }}")
            open_chain = True
            changed += 1
            i += 1
            continue

        m = DEFAULT.match(line)
        if m:
            # "default" after a fall-through cannot become "else" -- there is no
            # open chain for it to attach to. It runs unconditionally there,
            # which is what the original did too.
            out.append(f"{m.group(1)}else{m.group(2)}" if open_chain else m.group(1) + m.group(2).lstrip())
            open_chain = False
            changed += 1
            i += 1
            continue

        if CLOSE.match(line):
            open_chain = False
        out.append(line)
        i += 1

    return out, changed


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    total = 0
    for path in sys.argv[1:]:
        lines = open(path, encoding="utf-8").read().split("\n")
        new, n = convert(lines)
        text = "\n".join(new)
        text = re.sub(r"^use feature qw\(switch\);\n", "", text, flags=re.M)
        text = re.sub(r"^(use feature qw\()switch (.*\);)$", r"\1\2", text, flags=re.M)
        if n:
            open(path, "w", encoding="utf-8").write(text)
            print(f"  {path}: {n} construct(s)")
            total += n
    print(f"  {total} converted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
