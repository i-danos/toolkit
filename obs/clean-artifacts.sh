#!/bin/bash
# Drop accidentally committed build output from each repository's index.
#
# Where it came from: during the 2026-08-20 round of grouped commits, git add
# swept in the debhelper output the local build had left in the working tree.
# The local build runs dpkg-buildpackage -b — binary only, no source package —
# so these files never produced a symptom, right up until source packages had
# to be generated for OBS and dpkg-source reported them as unwanted binary
# files.
#
# Only debhelper's deterministic output is matched. Broad rules such as
# *.o / *.so are avoided because they would also catch binaries the
# repositories legitimately carry (firmware, test fixtures). Staging
# directories of the form debian/<binary package>/ are verified one by one
# against the Package: fields in debian/control.

set -u
SRC=/home/aikon/danos/build-iso/danos-sources
MODE=${MODE:-dry}     # dry = list only; apply = actually git rm --cached and commit

cd "$SRC" || exit 1
mapfile -t pkgs < <(grep -vE '^\s*(#|$)' /home/aikon/danos/build-iso/danos-sources/toolkit/build/build_order.txt \
                    | sed 's/\s*#.*//' | grep .)

total=0; repos=0
for p in "${pkgs[@]}"; do
  [ -d "$p/.git" ] || continue

  # Binary package names declared in debian/control -> their staging directories
  mapfile -t bins < <(git -C "$p" show HEAD:debian/control 2>/dev/null \
                      | sed -n 's/^Package:[[:space:]]*//p' | tr -d '\r')

  paths=()
  while IFS= read -r f; do paths+=("$f"); done < <(
    git -C "$p" ls-files 2>/dev/null | awk -v bl="$(printf '%s\n' "${bins[@]}" | paste -sd'|')" '
      /^debian\/tmp\// {print; next}
      /^debian\/\.debhelper\// {print; next}
      /^debian\/files$/ {print; next}
      /^debian\/[^\/]+\.substvars$/ {print; next}
      /^debian\/[^\/]+\.debhelper\.log$/ {print; next}
      /^debian\/debhelper-build-stamp$/ {print; next}
      /^debian\/autoreconf\./ {print; next}
      bl != "" && $0 ~ "^debian/(" bl ")/" {print; next}
    '
  )

  n=${#paths[@]}
  [ "$n" -eq 0 ] && continue
  repos=$((repos+1)); total=$((total+n))
  printf '%-42s %5d files\n' "$p" "$n"

  if [ "$MODE" = apply ]; then
    printf '%s\0' "${paths[@]}" | xargs -0 git -C "$p" rm -r --cached --quiet -- 2>/dev/null

    # Add a .gitignore so the next git add does not pick them up again
    gi="$p/debian/.gitignore"
    if [ ! -f "$gi" ] || ! grep -q '^/tmp/$' "$gi" 2>/dev/null; then
      {
        echo "/tmp/"
        echo "/.debhelper/"
        echo "/files"
        echo "/*.substvars"
        echo "/*.debhelper.log"
        echo "/debhelper-build-stamp"
        echo "/autoreconf.*"
        for b in "${bins[@]}"; do [ -n "$b" ] && echo "/$b/"; done
      } >> "$gi"
      git -C "$p" add debian/.gitignore
    fi

    git -C "$p" commit --quiet -m "Stop tracking debhelper build output

These files are produced by dpkg-buildpackage and were swept into the tree
by an over-broad git add. The local build uses -b (binary only) and never
builds a source package, so they caused no symptom; dpkg-source rejects
them as unwanted binary files when building for OBS.

Add debian/.gitignore so they stay untracked." 2>/dev/null \
      && echo "    -> cleanup committed" || echo "    -> commit failed"
  fi
done

echo
echo "$repos repositories affected, $total files   (MODE=$MODE)"
