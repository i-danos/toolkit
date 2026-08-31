#!/bin/bash
# Check that every built package can be pushed, and that nothing is stranded.
#
# The trap this closes: a repository with no i-danos remote configured has
# nowhere for `git push` to go, so a fix committed there stays on the build
# host and nothing says so. vyatta-login hit exactly that -- the GitHub
# repository existed the whole time, only the local remote was missing, and the
# gap sits between committing a fix and publishing it, which is easy to walk
# past.
#
# Two questions, which are not the same:
#
#   configured   does this clone have an i-danos remote at all
#   stranded     does it hold commits of ours that are on no i-danos branch
#
# A repository can be unconfigured and perfectly safe (an untouched clone), or
# configured and still stranded (committed but never pushed). Only the second
# is data at risk; the first is a trap waiting for whoever fixes something
# there next.
#
# Everything that touches the network runs in parallel. Serially this took
# longer than 900s across 148 repositories and got killed.
#
# Usage: 95-check_remotes.sh [--fix] [--fetch]
#          --fix    add missing remotes (never pushes)
#          --fetch  refresh remote-tracking refs first; without it the
#                   stranded check uses whatever refs are already on disk,
#                   which is enough to spot work that was never pushed at all

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ORDER_FILE="${BUILD_ORDER_FILE:-$SCRIPT_DIR/build_order.txt}"
SOURCES_DIR="${SOURCES_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
JOBS="${JOBS:-12}"

FIX=0
FETCH=0
for a in "$@"; do
    case "$a" in
        --fix)   FIX=1 ;;
        --fetch) FETCH=1 ;;
        *) echo "usage: $(basename "$0") [--fix] [--fetch]" >&2; exit 2 ;;
    esac
done

export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=12}"
export SOURCES_DIR

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

grep -vE '^\s*#|^\s*$' "$BUILD_ORDER_FILE" | awk '{print $1}' | sort -u \
    | while read -r r; do
          [ -d "$SOURCES_DIR/$r/.git" ] && echo "$r"
      done > "$work/repos"

# Split by whether a remote is already configured.
: > "$work/configured"; : > "$work/unconfigured"
while read -r r; do
    if git -C "$SOURCES_DIR/$r" remote | grep -qE '^(i-danos|fork)$'; then
        echo "$r" >> "$work/configured"
    else
        echo "$r" >> "$work/unconfigured"
    fi
done < "$work/repos"

# Does an upstream exist for the unconfigured ones? ls-remote over ssh rather
# than the GitHub API, which rate-limits well below 148 requests.
if [ -s "$work/unconfigured" ]; then
    xargs -P "$JOBS" -I{} sh -c '
        if git ls-remote --exit-code -h "git@github.com:i-danos/{}.git" >/dev/null 2>&1
        then echo "have {}"; else echo "none {}"; fi' \
        < "$work/unconfigured" > "$work/probe" 2>/dev/null
else
    : > "$work/probe"
fi

if [ "$FETCH" -eq 1 ] && [ -s "$work/configured" ]; then
    xargs -P "$JOBS" -I{} sh -c '
        cd "$SOURCES_DIR/{}" || exit 0
        rem=$(git remote | grep -E "^(i-danos|fork)$" | head -1)
        [ -n "$rem" ] && git fetch "$rem" --quiet 2>/dev/null' \
        < "$work/configured" >/dev/null 2>&1
fi

# Commits of ours that no i-danos branch contains.
if [ -s "$work/configured" ]; then
    xargs -P "$JOBS" -I{} sh -c '
        cd "$SOURCES_DIR/{}" || exit 0
        rem=$(git remote | grep -E "^(i-danos|fork)$" | head -1)
        # HEAD must be named explicitly. git log defaults to HEAD only when it
        # is given no revision at all, and "--not --remotes=..." is a revision
        # argument -- so the obvious "git log --not --remotes=X" walks from
        # nothing and prints nothing, for every repository, always. This check
        # reported "nothing stranded" while vyatta-dataplane held 15 commits
        # that were on no remote branch.
        #
        # Count ours separately from the total. Most of these clones came from
        # upstream danos with history our fork has never been pushed, so the
        # raw count is dominated by commits that were never ours to publish --
        # pyang alone shows 1433. Only the ones we wrote are work at risk.
        n=$(git rev-list --count HEAD --not --remotes="$rem" 2>/dev/null)
        mine=$(git rev-list --count --author=i-danos HEAD --not --remotes="$rem" 2>/dev/null)
        [ "${mine:-0}" -gt 0 ] &&
            echo "{} ($mine of $n on $(git rev-parse --abbrev-ref HEAD))"' \
        < "$work/configured" > "$work/stranded" 2>/dev/null
else
    : > "$work/stranded"
fi

# grep -c prints 0 and exits 1 when nothing matches; a `|| echo 0` here would
# append a second line and the count would print as "0\n0".
missing=$(grep -c '^have ' "$work/probe" 2>/dev/null); missing=${missing:-0}
absent=$(grep -c '^none ' "$work/probe" 2>/dev/null); absent=${absent:-0}

if [ "$FIX" -eq 1 ] && [ "$missing" -gt 0 ]; then
    grep '^have ' "$work/probe" | awk '{print $2}' | while read -r r; do
        git -C "$SOURCES_DIR/$r" remote add i-danos \
            "git@github.com:i-danos/$r.git" 2>/dev/null
    done
fi

printf 'configured   %s\n' "$(wc -l < "$work/configured")"
printf 'no remote    %s%s\n' "$missing" \
    "$([ "$FIX" -eq 1 ] && echo ' (added)' || echo ' -- rerun with --fix')"
printf 'no upstream  %s\n' "$absent"
[ "$absent" -gt 0 ] && grep '^none ' "$work/probe" | awk '{print "  "$2}'

if [ -s "$work/stranded" ]; then
    printf '\nstranded -- committed here, on no i-danos branch:\n'
    sed 's/^/  /' "$work/stranded"
    exit 1
fi

printf '\nnothing stranded\n'
