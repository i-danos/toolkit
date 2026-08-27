#!/bin/bash
# Build Debian source packages (.dsc + tarball) for OBS from a clean git export.
#
# Why not the working tree: 120 of the 149 repositories carry build leftovers
# (.o/.so, debian/tmp, autotools-regenerated configure and Makefile.in). The
# local build runs dpkg-buildpackage -b — binary only, never a source package —
# so those leftovers have always been harmless. OBS needs a complete source
# package, where including them is both bloat and a way for the build to take a
# different path than it does locally. git archive HEAD takes the committed
# state: clean and reproducible.
#
# Why quilt packages need an orig synthesized here: 3.0 (quilt) requires
# <package>_<upstream version>.orig.tar.*, and not one repository has one (the
# local binary build does not need them). It is synthesized from the export with
# debian/ removed, which matches quilt semantics — the patches live in
# debian/patches and are not applied to the tree.

set -u
SRC=/home/aikon/danos/build-iso/danos-sources
OUT=${OUT:-${OBS_DIR:-/home/aikon/danos/.obs}/dsc}
STAGE=${STAGE:-${OBS_DIR:-/home/aikon/danos/.obs}/stage}
FIXES=${FIXES:-${OBS_DIR:-/home/aikon/danos/.obs}/fixes}

mkdir -p "$OUT" "$STAGE"

pkgs=("$@")
if [ ${#pkgs[@]} -eq 0 ]; then
  mapfile -t pkgs < <(grep -vE '^\s*(#|$)' /home/aikon/danos/build-iso/scripts/build_order.txt \
                      | sed 's/\s*#.*//' | grep .)
fi

ok=0; fail=0
for p in "${pkgs[@]}"; do
  repo="$SRC/$p"
  if [ ! -d "$repo/.git" ]; then
    printf '  %-42s SKIP  not a git repository\n' "$p"; fail=$((fail+1)); continue
  fi
  # Which ref to export. Normally HEAD, but golang-github-mdlayher-netlink's
  # i-danos/2608 was branched from origin/upstream (the wrong baseline was
  # picked when the branches were created) and points at a pure upstream import
  # commit with no debian/ at all; the packaging is on main. Fall back to a
  # local branch that has debian/changelog and warn loudly — this is a defect in
  # the repository and should not be swallowed silently.
  ref=HEAD
  if ! git -C "$repo" cat-file -e "HEAD:debian/changelog" 2>/dev/null; then
    for cand in $(git -C "$repo" branch --format='%(refname:short)' 2>/dev/null); do
      if git -C "$repo" cat-file -e "$cand:debian/changelog" 2>/dev/null; then ref="$cand"; break; fi
    done
    if [ "$ref" = HEAD ]; then
      printf '  %-42s SKIP  no debian/changelog on any branch\n' "$p"; fail=$((fail+1)); continue
    fi
    printf '  %-42s WARN  HEAD has no debian/, using branch %s\n' "$p" "$ref"
  fi

  # Always take the source package name and version from the changelog, never
  # guess them from the directory name — the two often differ (the golang-dbus
  # directory holds the source package golang-github-godbus-dbus).
  src=$(git -C "$repo" show "$ref":debian/changelog 2>/dev/null | head -1 | awk '{print $1}')
  ver=$(git -C "$repo" show "$ref":debian/changelog 2>/dev/null | head -1 \
        | sed -n 's/.*(\([^)]*\)).*/\1/p')
  [ -n "$src" ] && [ -n "$ver" ] || { printf '  %-42s FAIL  cannot parse name/version from changelog\n' "$p"; fail=$((fail+1)); continue; }

  # Strip the epoch (filenames do not carry it), then split off the upstream version
  vnoep=${ver#*:}
  upstream=${vnoep%-*}
  [ "$upstream" = "$vnoep" ] || true   # no hyphen means native

  fmt=$(git -C "$repo" show "$ref":debian/source/format 2>/dev/null | tr -d '\n' || echo '1.0')

  work="$STAGE/${src}-${upstream}"
  rm -rf "$work"; mkdir -p "$work"
  if ! git -C "$repo" archive "$ref" | tar -x -C "$work" 2>/dev/null; then
    printf '  %-42s FAIL  git archive failed\n' "$p"; rm -rf "$work"; fail=$((fail+1)); continue
  fi

  # Prune accidentally committed debhelper output.
  #
  # During the 2026-08-20 round of grouped commits, git add swept in the output
  # the local build had left in the working tree — 28 repositories, roughly 4000
  # files. The local build runs dpkg-buildpackage -b (binary only, no source
  # package), so it never showed a symptom; once source packages were needed for
  # OBS, dpkg-source rejected them as unwanted binary files under quilt/1.0,
  # while the native format would have silently shipped them.
  #
  # The proper fix is git rm --cached in each repository, but the .git metadata
  # of 189 repositories is owned by root (the round that rewrote committer names
  # ran filter-branch as root), so the current user cannot commit. Pruning the
  # export gives the same result as the cleanup and needs no git write access.
  # Only debhelper's deterministic output is matched; broad *.o/*.so rules are
  # avoided because they would also catch binaries the repositories legitimately
  # carry.
  mapfile -t bins < <(git -C "$repo" show "$ref":debian/control 2>/dev/null \
                      | sed -n 's/^Package:[[:space:]]*//p' | tr -d '\r')
  rm -rf "$work/debian/tmp" "$work/debian/.debhelper" "$work/debian/autoreconf."* 2>/dev/null
  rm -f  "$work/debian/files" "$work/debian/debhelper-build-stamp" \
         "$work/debian/"*.substvars "$work/debian/"*.debhelper.log 2>/dev/null
  for b in "${bins[@]}"; do
    [ -n "$b" ] && [ -d "$work/debian/$b" ] && rm -rf "$work/debian/$b"
  done

  # Apply the fix patches under .obs/fixes/<package>/.
  #
  # These address problems a clean OBS build exposes and the local build cannot
  # see: GCC 14's promoted errors are suppressed by -Wno-error in
  # 50-build_danos_packages.sh, and incomplete Build-Depends are masked by the
  # cumulative chroot. The patches live here rather than in the repositories
  # because the .git directories of 189 repositories are owned by root and the
  # current user cannot commit; once that ownership is fixed they should be
  # committed into each repository.
  if [ -d "$FIXES/$p" ]; then
    for pt in "$FIXES/$p"/*.patch; do
      [ -e "$pt" ] || continue
      if (cd "$work" && patch -p1 -f --dry-run -i "$pt" >/dev/null 2>&1); then
        (cd "$work" && patch -p1 -f -i "$pt" >/dev/null 2>&1)
        printf '  %-42s FIX   %s\n' "$p" "$(basename "$pt")"
      else
        printf '  %-42s WARN  fix patch does not apply: %s\n' "$p" "$(basename "$pt")"
      fi
    done
  fi

  # A fix patch may change debian/source/format — python-vici's switches native
  # to quilt — while the fmt read above came from git. Re-read it from the
  # patched export, or a format-changing patch is silently ignored by the case
  # below.
  if [ -f "$work/debian/source/format" ]; then
    fmt=$(tr -d '\n' < "$work/debian/source/format")
  fi

  case "$fmt" in
    *quilt*)
      # A few repositories (libre, mstpd, makedumpfile,
      # ufispace-apollo-linux-modules) have git trees in the patches-applied
      # state while debian/patches/series still lists those patches. Synthesizing
      # an orig from such a tree makes dpkg-source apply them a second time:
      # "Reversed (or previously applied) patch detected"。
      # So reverse them out one at a time, in reverse order, to recover the
      # actual upstream state.
      if [ -f "$work/debian/patches/series" ]; then
        while IFS= read -r pt; do
          pt=${pt%%[[:space:]]*}
          [ -z "$pt" ] && continue
          case "$pt" in \#*) continue;; esac
          [ -f "$work/debian/patches/$pt" ] || continue
          # -F 0 has to match dpkg-source. It applies patches forward with
          #   patch -t -F 0 -N -p1 -u -V never -E -B .pc/...
          # while patch allows fuzz by default. Reversing with fuzz produces a
          # tree dpkg-source cannot reproduce at zero fuzz, reported as:
          #   Hunk #1 FAILED at 1353.
          #   dpkg-source: info: the patch has fuzz which is not allowed, or is malformed
          # Anything that will not reverse cleanly is left as is for
          # dpkg-source to judge; never force it.
          if (cd "$work" && patch -R -p1 -F 0 -f --dry-run -i "debian/patches/$pt" >/dev/null 2>&1); then
            (cd "$work" && patch -R -p1 -F 0 -f -i "debian/patches/$pt" >/dev/null 2>&1)
          fi
        done < <(tac "$work/debian/patches/series")
      fi

      # Must land in dpkg-source's CWD ($OUT) — it looks for the orig only in
      # the current directory, and anywhere else gives
      # "no upstream tarball found at ./<pkg>_<version>.orig.tar.{...}"
      orig="$OUT/${src}_${upstream}.orig.tar.gz"
      tar -czf "$orig" -C "$STAGE" --exclude="${src}-${upstream}/debian" "${src}-${upstream}" 2>/dev/null
      ;;
  esac

  # dpkg-source writes its output to CWD, so run it inside OUT
  if (cd "$OUT" && dpkg-source --no-check -b "$work" >/dev/null 2>&1); then
    sz=$(du -sh --apparent-size "$OUT/${src}_"*.tar.* 2>/dev/null | awk '{s=$1} END{print s}')
    printf '  %-42s OK    %-16s %-14s %s\n' "$p" "$ver" "${fmt:-1.0}" "${sz:-?}"
    ok=$((ok+1))
  else
    printf '  %-42s FAIL  dpkg-source -b\n' "$p"
    fail=$((fail+1))
  fi
  rm -rf "$work"
done

echo
echo "$ok generated, $fail failed/skipped"
echo "output: $OUT  ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
