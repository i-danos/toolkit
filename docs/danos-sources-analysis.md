# DANOS Source Code Analysis Report

**Date:** December 3, 2025
**Scope:** `/build-iso/danos-sources` (189 local repositories)
**Objective:** Compare local source code against the original state to identify excessive or unnecessary modifications.

## 1. Executive Summary

A comprehensive scan of the 189 local repositories in `danos-sources` was performed. The analysis checked for uncommitted changes, local commits, and untracked files.

*   **Total Repositories Scanned:** 189
*   **Repositories with Logic Changes:** 1 (`vyatta-version`)
*   **Repositories with Configuration/Build System Updates:** 1 (`vyatta-vmware-tools`)
*   **Repositories with Permission Changes Only:** 4 (`vyatta-service-gnss`, `vyatta-snmp-vrf-agent`, `yang`, `yangd`)
*   **Repositories with Build Artifacts (Dirty):** ~30+ (Contains untracked files like `debian/.debhelper`, `config.log`, etc.)

**Conclusion:** The modifications found are **not excessive**. The logic changes are confined to a single repository (`vyatta-version`) and appear necessary for branding and versioning the "Kington" release. Other changes are standard build system updates or permission fixes required for the build process. The presence of build artifacts indicates that the repositories were built in-place and not cleaned, but this does not constitute a modification of the source code logic.

## 2. Detailed Analysis of Modifications

### 2.1. `vyatta-version` (Logic Changes)
This repository contains the most significant changes, aimed at customizing the OS release information.

*   **File:** `debian/postrm`
    *   **Change:** Fixed a syntax error (missing line continuation `\`) in the `purge|remove|...` case block.
    *   **Verdict:** **Necessary fix.**

*   **File:** `scripts/gen_files`
    *   **Change:**
        *   Modified `create_os_release_vyatta` to include `VERSION_CODENAME` and append the project name (e.g., "Kington") to `PRETTY_NAME`.
        *   Added a "Shipping" timestamp format `(DANOS:Shipping:<VERSION>:<DATE>)` to the version string.
    *   **Verdict:** **Necessary customization** for the specific build target (Kington).

*   **File:** `scripts/get_vyatta_version`
    *   **Change:**
        *   Added fallback logic to locate `_buildconfig` in parent directories.
        *   Set a default `PROJECT_ID` of "Kington" if not specified.
    *   **Verdict:** **Necessary** to ensure the build process can determine the version and project identity correctly in this environment.

### 2.2. `vyatta-vmware-tools` (Build System Update)
*   **Files:** `config/install-sh`, `config/missing`
*   **Change:** These files were updated from version `2012-01-06.13` to `2018-03-07.03`.
*   **Context:** These are standard GNU Autotools helper scripts. The update likely occurred automatically when `autoreconf` was run during the build.
*   **Verdict:** **Harmless and expected.** This ensures compatibility with the build environment's toolchain.

### 2.3. Permission Changes (`debian/rules`)
The following repositories had the executable bit (`chmod +x`) set on `debian/rules`:
*   `vyatta-service-gnss`
*   `vyatta-snmp-vrf-agent`
*   `yang`
*   `yangd`
*   **Verdict:** **Necessary.** The `debian/rules` file must be executable for the Debian package build process (`dpkg-buildpackage`) to function correctly.

## 3. Build Artifacts (Untracked Files)
Many repositories contain untracked files and directories, such as:
*   `debian/.debhelper/`
*   `debian/*.substvars`
*   `debian/*.debhelper.log`
*   `autom4te.cache/`
*   `config.log`, `config.status`
*   `Makefile` (generated from `Makefile.in`)

**Examples:** `vyatta-interfaces`, `vyatta-ipmi`, `vyatta-login`, `vyatta-op`, etc.

**Verdict:** These are **temporary build byproducts**. While they make the source tree "dirty," they do not represent changes to the source code itself. It is recommended to run `git clean -fdx` in these repositories if a clean source state is desired, but their presence does not negatively impact the integrity of the code.

## 4. Recommendations
1.  **Accept Changes:** The changes in `vyatta-version` should be preserved as they define the release identity.
2.  **Clean Repositories:** To restore the "pristine" state of the source directories (excluding the necessary changes), run the following command in the `danos-sources` directory:
    ```bash
    for d in */; do (cd "$d" && git clean -fdx); done
    ```
    *Note: This will remove all build artifacts.*
3.  **Commit Fixes:** If the `debian/rules` permission changes and `vyatta-version` fixes are intended to be permanent, they should be committed to the local git repositories.
