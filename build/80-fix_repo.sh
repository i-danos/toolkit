#!/bin/bash
set -e

# DANOS Local APT Repository Fix and Enhancement Script
# This script maintains a flat APT repository and provides intelligent package dependency resolution

# Configuration
REPO_DIR="${REPO_DIR:-/build-iso/danos-build/local-repo}"
CODENAME="${CODENAME:-2111}"
LABEL="${LABEL:-DANOS ${CODENAME} Local Repository}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional config roots (unused today but kept for compatibility)
CONFIG_DIR="${CONFIG_DIR:-}"   # e.g. /build-iso/danos-2111/config
PACKAGE_LISTS_DIR="${CONFIG_DIR:+${CONFIG_DIR}/package-lists}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"; }
log_warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1"; }
log_error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; }
log_debug() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $1"; }

# Function to check if a package exists in the repository
package_exists() {
    local pkg="$1"
    # Check for exact match or with version
    [ -f "${REPO_DIR}/${pkg}.deb" ] || [ -n "$(find "${REPO_DIR}" -name "${pkg}_*.deb" | head -1)" ]
}

# Function to extract dependencies from a .deb file
extract_dependencies() {
    local deb_file="$1"
    dpkg-deb -f "$deb_file" Depends 2>/dev/null | tr ',' '\n' | sed 's/ *//g' | sed 's/ *(.*)//g' | grep -v '^$' || true
}

# Function to resolve package dependencies recursively
resolve_dependencies() {
    local pkg="$1"
    local visited_file="$2"
    local depth="${3:-0}"

    # Prevent infinite recursion
    if [ "$depth" -gt 10 ]; then
        log_warn "Maximum dependency depth reached for $pkg"
        return
    fi

    # Check if already visited
    if grep -q "^${pkg}$" "$visited_file" 2>/dev/null; then
        return
    fi

    echo "$pkg" >> "$visited_file"

    # Find the .deb file
    local deb_file
    deb_file=$(find "$REPO_DIR" -name "${pkg}_*.deb" | head -1)
    if [ -z "$deb_file" ]; then
        log_warn "Package $pkg not found in repository"
        return
    fi

    log_debug "Resolving dependencies for $pkg (depth: $depth)"

    # Extract and resolve dependencies
    local deps
    deps=$(extract_dependencies "$deb_file")
    for dep in $deps; do
        # Skip version constraints and alternatives
        dep=$(echo "$dep" | cut -d'|' -f1 | cut -d':' -f1 | xargs)
        if [ -n "$dep" ] && package_exists "$dep"; then
            resolve_dependencies "$dep" "$visited_file" $((depth + 1))
        fi
    done
}

# Function to generate complete package list with dependencies
generate_complete_package_list() {
    local output_file="$1"
    local temp_file
    temp_file=$(mktemp)

    log_info "Generating complete package list with dependencies..."

    # Get all packages from repository
    local all_packages
    all_packages=$(find "$REPO_DIR" -name "*.deb" -exec basename {} \; | sed 's/_.*\.deb$//' | sort | uniq)

    # Resolve dependencies for each package
    for pkg in $all_packages; do
        resolve_dependencies "$pkg" "$temp_file"
    done

    # Sort and deduplicate
    sort "$temp_file" | uniq > "$output_file"
    rm "$temp_file"

    log_info "Generated package list with $(wc -l < "$output_file") packages"
}

# Function to check for missing dependencies
check_missing_dependencies() {
    local package_list="$1"
    local missing_deps_file="$2"

    log_info "Checking for missing dependencies..."

    > "$missing_deps_file"

    while IFS= read -r pkg; do
        local deb_file
        deb_file=$(find "$REPO_DIR" -name "${pkg}_*.deb" | head -1)
        if [ -n "$deb_file" ]; then
            local deps
            deps=$(extract_dependencies "$deb_file")
            for dep in $deps; do
                dep=$(echo "$dep" | cut -d'|' -f1 | cut -d':' -f1 | xargs)
                if [ -n "$dep" ] && ! package_exists "$dep" && ! grep -q "^${dep}$" "$package_list"; then
                    echo "$pkg:$dep" >> "$missing_deps_file"
                fi
            done
        fi
    done < "$package_list"

    local missing_count
    missing_count=$(wc -l < "$missing_deps_file")
    if [ "$missing_count" -gt 0 ]; then
        log_warn "Found $missing_count missing dependencies"
        log_info "Missing dependencies saved to $missing_deps_file"
    else
        log_info "No missing dependencies found"
    fi
}

# Function to update repository metadata
update_repo_metadata() {
    log_info "Updating repository metadata in ${REPO_DIR}..."

    cd "$REPO_DIR"

    # Generate flat repo metadata (Packages, Packages.gz, Packages.xz optional)
    log_debug "Generating Packages files..."
    dpkg-scanpackages . /dev/null > Packages
    gzip -9c Packages > Packages.gz
    if command -v xz >/dev/null 2>&1; then
        xz -9c Packages > Packages.xz
    fi

    # Generate Release with apt-ftparchive to include self-checksums and canonical formatting
    log_debug "Generating Release file via apt-ftparchive..."
    local release_conf
    release_conf=$(mktemp)
    cat > "$release_conf" <<EOF
APT::FTPArchive::Release {
    Origin "DANOS";
    Label "${LABEL}";
    Suite "danos";
    Codename "${CODENAME}";
    Architectures "amd64";
    Components "main";
    Description "DANOS Local Repository";
};
Dir::ArchiveDir ".";
Dir::Cache ".";
Default::Date::Compress "false";
EOF

    apt-ftparchive -c "$release_conf" release . > Release
    rm -f "$release_conf"

    # Provide InRelease (unsigned) for tools that prefer it
    cp Release InRelease

    log_info "Repository metadata updated (Release/InRelease with hashes)."
}

# Main script logic
main() {
    local action="${1:-update}"

    case "$action" in
        "update")
            update_repo_metadata
            ;;
        "generate-list")
            local output_file="${2:-/tmp/complete-package-list.txt}"
            generate_complete_package_list "$output_file"
            ;;
        "check-deps")
            local package_list="${2:-/tmp/complete-package-list.txt}"
            local missing_file="${3:-/tmp/missing-dependencies.txt}"
            if [ ! -f "$package_list" ]; then
                generate_complete_package_list "$package_list"
            fi
            check_missing_dependencies "$package_list" "$missing_file"
            ;;
        "full-fix")
            log_info "Running full repository fix..."
            update_repo_metadata
            local package_list="/tmp/complete-package-list.txt"
            generate_complete_package_list "$package_list"
            local missing_file="/tmp/missing-dependencies.txt"
            check_missing_dependencies "$package_list" "$missing_file"
            if [ -s "$missing_file" ]; then
                log_warn "Some dependencies are still missing. Check $missing_file"
            else
                log_info "All dependencies resolved successfully"
            fi
            ;;
        *)
            echo "Usage: $0 {update|generate-list|check-deps|full-fix}"
            echo "  update: Update repository metadata"
            echo "  generate-list [output_file]: Generate complete package list with dependencies"
            echo "  check-deps [package_list] [missing_file]: Check for missing dependencies"
            echo "  full-fix: Run complete repository fix and dependency check"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
