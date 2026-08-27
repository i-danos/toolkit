import os
import subprocess

root_dir = "/build-iso/danos-sources"
repos_with_changes = []

def get_git_status(repo_path):
    try:
        # Check for uncommitted changes
        status = subprocess.check_output(["git", "status", "--porcelain"], cwd=repo_path).decode("utf-8")
        
        # Check for local commits (ahead of tracked branch)
        # This assumes there is a tracking branch. If not, it might fail or return empty.
        try:
            commits = subprocess.check_output(["git", "log", "@{u}..HEAD", "--oneline"], cwd=repo_path, stderr=subprocess.DEVNULL).decode("utf-8")
        except subprocess.CalledProcessError:
            commits = "" # No upstream or detached head
            
        return status, commits
    except Exception as e:
        return None, None

def get_git_diff_stat(repo_path):
    try:
        diff = subprocess.check_output(["git", "diff", "--stat"], cwd=repo_path).decode("utf-8")
        return diff
    except:
        return ""

print(f"Scanning repositories in {root_dir}...")

subdirs = [os.path.join(root_dir, d) for d in os.listdir(root_dir) if os.path.isdir(os.path.join(root_dir, d))]
subdirs.sort()

for repo_path in subdirs:
    if not os.path.exists(os.path.join(repo_path, ".git")):
        continue
        
    status, commits = get_git_status(repo_path)
    
    has_changes = False
    report_entry = f"Repository: {os.path.basename(repo_path)}\n"
    
    if status:
        has_changes = True
        report_entry += "  Uncommitted Changes:\n"
        for line in status.splitlines():
            report_entry += f"    {line}\n"
        
        diff_stat = get_git_diff_stat(repo_path)
        if diff_stat:
             report_entry += "  Diff Stat:\n"
             for line in diff_stat.splitlines():
                 report_entry += f"    {line}\n"

    if commits:
        has_changes = True
        report_entry += "  Local Commits:\n"
        for line in commits.splitlines():
            report_entry += f"    {line}\n"
            
    if has_changes:
        repos_with_changes.append(report_entry)

print(f"Found {len(repos_with_changes)} repositories with modifications.")
print("-" * 40)
for entry in repos_with_changes:
    print(entry)
    print("-" * 40)
