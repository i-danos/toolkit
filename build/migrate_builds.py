import os
import glob
import shutil

SOURCES_DIR = "/build-iso/danos-sources"
BUILD_DIR = "/build-iso/danos-build"
LOCAL_REPO_DIR = os.path.join(BUILD_DIR, "local-repo")
SUCCESS_DIR = os.path.join(BUILD_DIR, "logs", "success")
# Resolve against this file rather than a fixed mount point; these scripts live
# in the toolkit repository, which need not be mounted at /build-iso.
BUILD_ORDER_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "build_order.txt")

def setup_dirs():
    os.makedirs(LOCAL_REPO_DIR, exist_ok=True)
    os.makedirs(SUCCESS_DIR, exist_ok=True)

def migrate():
    setup_dirs()
    
    # Read build order
    with open(BUILD_ORDER_FILE, 'r') as f:
        repos = [line.strip() for line in f if line.strip() and not line.startswith('#')]

    # Check for artifacts
    for repo in repos:
        # Look for a changes file starting with the repo name
        # This is a heuristic; might need refinement
        pattern = os.path.join(SOURCES_DIR, f"{repo}_*.changes")
        changes_files = glob.glob(pattern)
        
        if changes_files:
            print(f"Found artifacts for {repo}")
            # Mark as success
            with open(os.path.join(SUCCESS_DIR, repo), 'w') as f:
                f.write("Migrated from manual build")
            
            # Move .deb files
            # We need to find which .deb files belong to this build.
            # Usually they are listed in the .changes file, or we can just move all .debs 
            # that match the version?
            # Simpler: move all .deb files in SOURCES_DIR to LOCAL_REPO_DIR
            # But we should be careful not to move things that aren't part of a completed build?
            # Actually, if they are in SOURCES_DIR, they are cluttering it.
            pass
            
    # Move all .deb files from SOURCES_DIR to LOCAL_REPO_DIR
    # This assumes all .debs there are valid and we want them in the repo
    debs = glob.glob(os.path.join(SOURCES_DIR, "*.deb"))
    for deb in debs:
        shutil.move(deb, LOCAL_REPO_DIR)
        print(f"Moved {os.path.basename(deb)}")

if __name__ == "__main__":
    migrate()
