#!/bin/bash
# Commit .obs/fixes/<package>/*.patch into their respective repositories.
#
# These patches were previously applied only to the tree mk-dsc.sh exports,
# because the .git directories of 189 repositories were owned by root and could
# not be committed to. Run this once that ownership is fixed to land them in the
# repositories themselves.
#
# Usage: MODE=dry (default, only check that they apply) / MODE=apply (commit)
#
# linux-vyatta does not go through here: it has to be handled together with
# 8 uncommitted files, the SKIP markers in series, and the refreshed patches.
# See fixes/linux-vyatta/README.md.

set -u
SRC=/home/aikon/danos/build-iso/danos-sources
FIXES=${OBS_DIR:-/home/aikon/danos/.obs}/fixes
MODE=${MODE:-dry}

# Repositories whose directory name differs from the fixes directory name
# (fixes uses the OBS package name)
declare -A DIRMAP=(
  [python-pytest-lazy-fixture]=pytest-lazy-fixture
)

ok=0; fail=0; skip=0
for d in "$FIXES"/*/; do
  pkg=$(basename "$d")
  [ "$pkg" = linux-vyatta ] && { printf '  %-30s SKIP  handled separately, see its README.md\n' "$pkg"; skip=$((skip+1)); continue; }
  repo="$SRC/${DIRMAP[$pkg]:-$pkg}"
  [ -d "$repo/.git" ] || { printf '  %-30s FAIL  repository not found\n' "$pkg"; fail=$((fail+1)); continue; }

  patches=$(ls "$d"*.patch 2>/dev/null | sort)
  [ -n "$patches" ] || continue

  allok=1
  for p in $patches; do
    git -C "$repo" apply --check "$p" 2>/dev/null || { allok=0; break; }
  done

  if [ $allok -eq 0 ]; then
    printf '  %-30s FAIL  patch does not apply to current HEAD\n' "$pkg"
    for p in $patches; do
      git -C "$repo" apply --check "$p" 2>&1 | head -1 | sed 's/^/        /'
    done
    fail=$((fail+1)); continue
  fi

  if [ "$MODE" = apply ]; then
    for p in $patches; do
      git -C "$repo" apply "$p" || { printf '  %-30s FAIL  apply failed\n' "$pkg"; fail=$((fail+1)); continue 2; }
      # Use the patch's own Subject as the commit title, and everything between
      # Subject and the diff as the body
      subj=$(sed -n 's/^Subject: //p' "$p" | head -1)
      body=$(awk '/^Subject: /{f=1;next} /^(---|diff --git|Index: )/{exit} f' "$p" | sed '/^$/{ /./!d }')
      # Stage only the files the patch touches. This used to be git add -A,
      # which swept in the build leftovers sitting in the working tree
      # (autoreconf output, configure~ backups, quilt-applied patches). Fourteen
      # commits went badly out of scope as a result — libyang was the worst at
      # 2132 files — and each had to be redone afterwards.
      for f in $(sed -n 's|^+++ b/||p;s|^--- a/||p' "$p" | grep -v '^/dev/null' | sort -u); do
        git -C "$repo" add -f -- "$f" 2>/dev/null
      done
      printf '%s\n%s\n' "$subj" "$body" | git -C "$repo" commit --quiet -F - \
        && printf '  %-30s OK    %s\n' "$pkg" "$(basename "$p")" \
        || { printf '  %-30s FAIL  commit failed\n' "$pkg"; fail=$((fail+1)); continue 2; }
    done
    ok=$((ok+1))
  else
    printf '  %-30s OK    %s patches apply\n' "$pkg" "$(echo "$patches" | wc -w)"
    ok=$((ok+1))
  fi
done

echo
echo "$ok ready/committed, $fail failed, $skip skipped   (MODE=$MODE)"
