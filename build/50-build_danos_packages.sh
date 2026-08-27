#!/bin/bash
# DANOS Binary Package Build Script
# Builds packages in dependency order using a local apt repository

set -e

# Configuration
SOURCES_DIR="/build-iso/danos-sources"
BUILD_DIR="/build-iso/danos-build"
LOCAL_REPO_DIR="${BUILD_DIR}/local-repo"
LOG_DIR="${BUILD_DIR}/logs/builds"
SUCCESS_MARKER_DIR="${LOG_DIR}/success"
# Resolve against this script rather than a fixed mount point. These scripts
# live in the toolkit repository now, so where they appear inside the build
# container depends on how it was mounted; /build-iso is the source tree only.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ORDER_FILE="${BUILD_ORDER_FILE:-$SCRIPT_DIR/build_order.txt}"

# Set Build Profiles to skip OBS signing
export DEB_BUILD_PROFILES="noobs"
# Skip tests to speed up build and avoid environment issues
export DEB_BUILD_OPTIONS="nocheck"
export DEB_CFLAGS_APPEND="-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=declaration-after-statement -Wno-error"
DEFAULT_BUILD_OPTIONS="${DEB_BUILD_OPTIONS}"
# Prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export GIT_TERMINAL_PROMPT=0

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Setup Directories
mkdir -p "${LOCAL_REPO_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${SUCCESS_MARKER_DIR}"

# Setup Local Repo
if [ ! -f "${LOCAL_REPO_DIR}/Packages" ]; then
    touch "${LOCAL_REPO_DIR}/Packages"
fi

# Add Local Repo to Apt Sources if not already present
touch /etc/apt/sources.list 2>/dev/null || true
if ! grep -q "file:${LOCAL_REPO_DIR}" /etc/apt/sources.list; then
    echo "Adding local repo to sources.list..."
    echo "deb [trusted=yes] file:${LOCAL_REPO_DIR} ./" >> /etc/apt/sources.list
fi

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; }

ensure_deb_src_entries() {
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
    fi
}

detect_kernel_source() {
    local preferred=(
        "/lib/modules/5.4.0-trunk-vyatta-amd64"
        "/lib/modules/$(uname -r)"
    )

    for candidate in "${preferred[@]}"; do
        if [ -d "${candidate}/build" ]; then
            echo "$candidate"
            return 0
        fi
    done

    for candidate in /lib/modules/*; do
        if [ -d "${candidate}/build" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

declare -A PACKAGE_EXTRA_BUILD_OPTIONS

KERNEL_SOURCE_PATH="$(detect_kernel_source || true)"
if [ -n "$KERNEL_SOURCE_PATH" ]; then
    PACKAGE_EXTRA_BUILD_OPTIONS["dpdk"]="kernel_modules ksrc=${KERNEL_SOURCE_PATH}"
else
    warn "Kernel headers not found; dpdk kernel modules will be skipped unless headers are installed."
fi

update_local_repo() {
    log "Updating local repository metadata..."
    cd "${LOCAL_REPO_DIR}"
    dpkg-scanpackages . /dev/null > Packages
    gzip -9c Packages > Packages.gz
    xz -9c Packages > Packages.xz
    # Release embeds checksums of Packages/Packages.gz/Packages.xz. If it's
    # not regenerated alongside them, apt validates freshly-rebuilt packages
    # against stale checksums and rejects/mis-serves them -- this was the
    # real root cause behind widespread "Hash Sum mismatch" errors, not just
    # apt's list cache (which we also clear below to force a re-read).
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=DANOS \
        -o APT::FTPArchive::Release::Label="DANOS 2111 Local Repository" \
        -o APT::FTPArchive::Release::Suite=danos \
        -o APT::FTPArchive::Release::Codename=2111 \
        -o APT::FTPArchive::Release::Components=main \
        -o APT::FTPArchive::Release::Architectures=amd64 \
        release . > Release
    rm -f /var/lib/apt/lists/*local-repo*
    apt-get update
}

install_build_deps() {
    local repo_dir=$1
    log "Installing build dependencies for $(basename "$repo_dir")..."
    
    cd "$repo_dir"
    
    local arch
    arch=$(dpkg --print-architecture)

    # Use mk-build-deps to install dependencies
    # We use -i (install), -r (remove after), -t (tool) to use apt-get with force-yes for local repo
    # Added -a "$arch" to ensure Build-Depends-Arch are included
    if mk-build-deps -a "$arch" --install --remove \
        --tool='apt-get -o Debug::pkgProblemResolver=yes -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --no-install-recommends --yes --allow-unauthenticated --allow-downgrades' \
        debian/control; then
        return 0
    else
        return 1
    fi
}

build_package() {
    local repo_name=$1
    local repo_dir="${SOURCES_DIR}/${repo_name}"
    local build_log="${LOG_DIR}/${repo_name}.log"
    local build_options="$DEFAULT_BUILD_OPTIONS"

    if [ -n "${PACKAGE_EXTRA_BUILD_OPTIONS[$repo_name]}" ]; then
        build_options="${build_options} ${PACKAGE_EXTRA_BUILD_OPTIONS[$repo_name]}"
    fi
    build_options=$(echo $build_options)

    # Check for success marker
    if [ -f "${SUCCESS_MARKER_DIR}/${repo_name}" ]; then
        return 0
    fi

    if [ ! -d "$repo_dir" ]; then
        warn "Repository $repo_name not found. Skipping."
        return
    fi

    if [ ! -f "$repo_dir/debian/control" ]; then
        warn "Repository $repo_name has no debian/control. Skipping."
        return
    fi

    log "Building $repo_name..."
    
    # Install Deps
    if ! install_build_deps "$repo_dir" >> "$build_log" 2>&1; then
        error "Failed to install build dependencies for $repo_name. Check $build_log"
        return 1
    fi

    cd "$repo_dir"
    git clean -fdx 2>/dev/null || true
    

    
    # Build Package
    # -us -uc: Do not sign source or changes
    # -b: Build binary-only
    # -j$(nproc): Parallel build
    if DEB_BUILD_OPTIONS="$build_options" dpkg-buildpackage -us -uc -b -j$(nproc) >> "$build_log" 2>&1; then
        log "Successfully built $repo_name"
        touch "${SUCCESS_MARKER_DIR}/${repo_name}"
        
        # Move .deb files to local repo
        mv ../*.deb "${LOCAL_REPO_DIR}/" 2>/dev/null || true
        
        # Update repo so next packages can find these deps
        update_local_repo >> "$build_log" 2>&1
    else
        error "Failed to build $repo_name. Check $build_log"
        return 1
    fi
}

# Main Loop
ensure_deb_src_entries

if [ ! -f "$BUILD_ORDER_FILE" ] || [ ! -s "$BUILD_ORDER_FILE" ]; then
    warn "Build order file missing or empty. Running analyzer to generate a fresh build plan."
    if python3 "$SCRIPT_DIR/40-analyze_build_order.py" > "${BUILD_ORDER_FILE}.tmp"; then
        mv "${BUILD_ORDER_FILE}.tmp" "$BUILD_ORDER_FILE"
        log "Generated build order with 40-analyze_build_order.py"
    else
        error "Unable to generate build order."
        exit 1
    fi
fi

# Ensure we have basic build tools non-interactively
apt-get update -q
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" build-essential devscripts equivs dpkg-dev python3

count=1
total=$(wc -l < "$BUILD_ORDER_FILE")

while IFS= read -r repo; do
    repo_trimmed="${repo%%#*}"
    # Trim all surrounding whitespace, not one space. "${var%% }" matches a
    # single space, so an entry written "python-vici  # note" kept a trailing
    # space, "$SOURCES_DIR/python-vici " did not exist, and build_package
    # answered with "Repository not found. Skipping." -- a warning, not a
    # failure, so the build carried on without it.
    repo_trimmed="${repo_trimmed#"${repo_trimmed%%[![:space:]]*}"}"
    repo_trimmed="${repo_trimmed%"${repo_trimmed##*[![:space:]]}"}"

    if [ -z "$repo_trimmed" ] || [[ "$repo" =~ ^\# ]]; then
        [ -n "$repo" ] && log "Skipping commented entry: $repo"
        continue
    fi

    echo "---------------------------------------------------"
    echo -e "${BLUE}[$count/$total] Processing $repo_trimmed${NC}"
    build_package "$repo_trimmed" < /dev/null || warn "$repo_trimmed failed, continuing with next package"
    ((count++))
done < "$BUILD_ORDER_FILE"

log "Build process completed."
