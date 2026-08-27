#!/bin/bash
# Redo the fix commits that git add -A polluted.
#
# commit-fixes.sh used `git add -A`, which swept every working-tree change into
# the commit — and these working trees carry leftovers from local builds
# (autoreconf output, configure~ backups, quilt-applied patches). Ten commits
# ended up far wider than their patch, the worst being libyang at 2132 files.
#
# This rolls each affected commit back, restages only the files the patch
# actually touches, and recommits with the original message. linux-vyatta is
# excluded: that commit staged its files explicitly and is correct.
#
# Usage: MODE=dry (default, list only) / MODE=apply

set -u
SRC=/home/aikon/danos/build-iso/danos-sources
FIXES=/home/aikon/danos/.obs/fixes.disabled
MODE=${MODE:-dry}
declare -A DIRMAP=([python-pytest-lazy-fixture]=pytest-lazy-fixture)

for d in "$FIXES"/*/; do
  pkg=$(basename "$d")
  [ "$pkg" = linux-vyatta ] && continue
  repo="$SRC/${DIRMAP[$pkg]:-$pkg}"
  [ -d "$repo/.git" ] || continue

  patches=$(ls "$d"*.patch 2>/dev/null | sort)
  [ -n "$patches" ] || continue

  # The files the patch is supposed to touch
  want=$(for p in $patches; do
           sed -n 's|^+++ b/||p;s|^--- a/||p' "$p"
         done | grep -v '^/dev/null' | sort -u)
  nwant=$(echo "$want" | grep -c .)

  # Today's fix commits, excluding the build-output cleanup
  commits=$(git -C "$repo" log --since='2026-08-23 00:00' --format='%h|%s' 2>/dev/null \
            | grep -v 'Stop tracking debhelper build output' | cut -d'|' -f1)
  [ -n "$commits" ] || continue
  ncommit=$(echo "$commits" | grep -c .)

  # Total number of files actually in those commits
  ngot=$(for c in $commits; do git -C "$repo" show --stat --format='' "$c" | sed '$d' | grep -c '|'; done \
         | awk '{s+=$1} END{print s+0}')

  if [ "$ngot" -le "$nwant" ]; then
    printf '  %-32s clean (%s files, expected %s)\n' "$pkg" "$ngot" "$nwant"
    continue
  fi

  printf '  %-32s ** redo needed: committed %s files, expected %s **\n' "$pkg" "$ngot" "$nwant"

  if [ "$MODE" = apply ]; then
    base=$(git -C "$repo" rev-parse "$(echo "$commits" | tail -1)^" 2>/dev/null) || { echo "      cannot resolve base commit"; continue; }
    git -C "$repo" reset --mixed --quiet "$base" || { echo "      reset failed"; continue; }
    # Recommit patch by patch, staging only the files each one touches
    for p in $patches; do
      pw=$(sed -n 's|^+++ b/||p;s|^--- a/||p' "$p" | grep -v '^/dev/null' | sort -u)
      for f in $pw; do git -C "$repo" add -f -- "$f" 2>/dev/null; done
      subj=$(sed -n 's/^Subject: //p' "$p" | head -1)
      body=$(awk '/^Subject: /{f=1;next} /^(---|diff --git|Index: )/{exit} f' "$p")
      printf '%s\n%s\n' "$subj" "$body" | git -C "$repo" commit --quiet -F - \
        && printf '      redone %s (%s files)\n' "$(basename "$p")" "$(echo "$pw" | grep -c .)" \
        || printf '      commit failed %s\n' "$(basename "$p")"
    done
  fi
done
