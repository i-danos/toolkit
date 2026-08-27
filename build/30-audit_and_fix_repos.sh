#!/bin/bash
# Audit and Fix DANOS Repositories
# Checks for danos/2110a tag. If missing, switches to latest tag or default branch.

SOURCES_DIR="/build-iso/danos-sources"
LOG_FILE="/build-iso/danos-build/logs/repo_audit_$(date +%Y%m%d_%H%M%S).log"
TARGET_TAG="danos/2110a"
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=no"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "Starting Repository Audit in $SOURCES_DIR" | tee -a "$LOG_FILE"
echo "Target Tag: $TARGET_TAG" | tee -a "$LOG_FILE"
echo "---------------------------------------------------" | tee -a "$LOG_FILE"

count_target=0
count_latest_tag=0
count_default=0
count_error=0
count_empty=0

for repo_dir in "$SOURCES_DIR"/*; do
    if [ ! -d "$repo_dir" ]; then continue; fi
    repo_name=$(basename "$repo_dir")
    
    # Skip if not a git repo
    if [ ! -d "$repo_dir/.git" ]; then
        echo -e "${YELLOW}[SKIP] $repo_name : Not a git repository (or empty)${NC}" | tee -a "$LOG_FILE"
        ((count_empty++))
        continue
    fi

    cd "$repo_dir" || continue

    # Check if repo is currently locked (cloning)
    if [ -f ".git/index.lock" ]; then
         echo -e "${YELLOW}[SKIP] $repo_name : Git locked (cloning in progress?)${NC}" | tee -a "$LOG_FILE"
         continue
    fi

    # 1. Check if TARGET_TAG exists
    if git rev-parse "$TARGET_TAG" >/dev/null 2>&1; then
        # Tag exists, ensure it is checked out
        current_head=$(git rev-parse HEAD)
        target_head=$(git rev-parse "$TARGET_TAG")
        
        if [ "$current_head" == "$target_head" ]; then
            echo -e "${GREEN}[OK] $repo_name : On $TARGET_TAG${NC}" | tee -a "$LOG_FILE"
            ((count_target++))
        else
            echo -e "${BLUE}[FIX] $repo_name : Switching to $TARGET_TAG${NC}" | tee -a "$LOG_FILE"
            if git checkout "$TARGET_TAG" >> "$LOG_FILE" 2>&1; then
                ((count_target++))
            else
                echo -e "${RED}[ERR] $repo_name : Failed to checkout $TARGET_TAG${NC}" | tee -a "$LOG_FILE"
                ((count_error++))
            fi
        fi
    else
        # 2. Tag does NOT exist. Find latest tag.
        # Fetch tags just in case
        git fetch --tags >/dev/null 2>&1
        
        # Check again after fetch
        if git rev-parse "$TARGET_TAG" >/dev/null 2>&1; then
             echo -e "${BLUE}[FIX] $repo_name : Found $TARGET_TAG after fetch. Switching...${NC}" | tee -a "$LOG_FILE"
             git checkout "$TARGET_TAG" >> "$LOG_FILE" 2>&1
             ((count_target++))
             continue
        fi

        # Find latest tag by creator date
        latest_tag=$(git tag --sort=-creatordate | head -n 1)
        
        if [ -n "$latest_tag" ]; then
            echo -e "${YELLOW}[WARN] $repo_name : $TARGET_TAG missing. Switching to latest tag: $latest_tag${NC}" | tee -a "$LOG_FILE"
            if git checkout "$latest_tag" >> "$LOG_FILE" 2>&1; then
                ((count_latest_tag++))
            else
                 echo -e "${RED}[ERR] $repo_name : Failed to checkout $latest_tag${NC}" | tee -a "$LOG_FILE"
                 ((count_error++))
            fi
        else
            # No tags at all, use default branch
            default_branch=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
            if [ -z "$default_branch" ]; then default_branch="master"; fi
            
            echo -e "${YELLOW}[WARN] $repo_name : No tags found. Switching to default branch: $default_branch${NC}" | tee -a "$LOG_FILE"
            if git checkout "$default_branch" >> "$LOG_FILE" 2>&1; then
                git pull >> "$LOG_FILE" 2>&1
                ((count_default++))
            else
                 echo -e "${RED}[ERR] $repo_name : Failed to checkout $default_branch${NC}" | tee -a "$LOG_FILE"
                 ((count_error++))
            fi
        fi
    fi
done

echo "---------------------------------------------------" | tee -a "$LOG_FILE"
echo "Audit Complete." | tee -a "$LOG_FILE"
echo "Stats:" | tee -a "$LOG_FILE"
echo "  Target ($TARGET_TAG): $count_target" | tee -a "$LOG_FILE"
echo "  Latest Tag: $count_latest_tag" | tee -a "$LOG_FILE"
echo "  Default Branch: $count_default" | tee -a "$LOG_FILE"
echo "  Errors: $count_error" | tee -a "$LOG_FILE"
echo "  Empty/Skipped: $count_empty" | tee -a "$LOG_FILE"
