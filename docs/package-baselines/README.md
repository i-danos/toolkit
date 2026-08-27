# Package baselines

A snapshot from the start of the 2608 port, when the question was "what does
the old image contain, and what does the new one still owe it". Kept for
provenance: several retirement decisions in
[`../../build/build_order.txt`](../../build/build_order.txt) were argued from
these lists.

**These are data, not live checks.** Nothing regenerates them, and they do not
describe the 2608 image — for that, run
[`../../iso/verify-iso.sh`](../../iso/verify-iso.sh) against the ISO, or read
the manifest out of it directly.

| File | Lines | What it is |
|---|---|---|
| `danos-2105.packages` | 1384 | the 2105 image's manifest, `name version` per line |
| `danos-2105.packages.names` | 1384 | the same, names only |
| `danos-2105.packages.names.sorted` | 1384 | sorted |
| `build-filesystem.packages.sorted` | 1690 | the build filesystem's package set |
| `build-filesystem.packages.sorted.clean` | 1690 | the same with architecture qualifiers dropped (`binutils-common:amd64` → `binutils-common`) |
| `build-filesystem.packages.names` | 559 | a names-only subset |
| `missing_packages.txt` | 376 | in 2105, absent from the build filesystem |
| `extra_packages.txt` | 682 | in the build filesystem, absent from 2105 |
| `missing_packages_clean.txt` | 121 | filtered |
| `extra_packages_clean.txt` | 427 | filtered |

## On the `_clean` variants

For `build-filesystem.packages.sorted.clean` the rule is visible in a diff:
architecture qualifiers are stripped.

For `missing_packages` and `extra_packages` it is not. Both drop exactly 255
entries, which invites an explanation, but the obvious ones do not survive
checking: the two lists have no entries in common, so it is not an
intersection; and stripping architecture qualifiers changes neither line count,
so it is not that either. What the 255 have in common is that they are all
library and toolchain packages — `libacl1`, `gcc-8-base`, `binutils-common` —
which suggests a hand-maintained exclusion rather than a rule.

No generator was kept, so the filter cannot be recovered from the data. Treat
the `_clean` files as someone's edited working copy and the unfiltered ones as
the record.
