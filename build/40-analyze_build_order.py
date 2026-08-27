import os
import re
import sys
from collections import defaultdict, deque

SOURCES_DIR = "/build-iso/danos-sources"

def parse_control_file(repo_path):
    control_path = os.path.join(repo_path, "debian", "control")
    if not os.path.exists(control_path):
        return None, [], []

    source_pkg = None
    binary_pkgs = []
    build_depends = []

    with open(control_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
        
        # Extract Source package name
        source_match = re.search(r'^Source:\s+(.+)$', content, re.MULTILINE)
        if source_match:
            source_pkg = source_match.group(1).strip()

        # Extract Binary package names
        binary_matches = re.findall(r'^Package:\s+(.+)$', content, re.MULTILINE)
        binary_pkgs = [b.strip() for b in binary_matches]

        # Extract Build-Depends
        # This is a bit complex because it can span multiple lines and has version constraints
        # We'll look for the first paragraph (Source paragraph)
        paragraphs = content.split('\n\n')
        source_paragraph = paragraphs[0]
        
        bd_match = re.search(r'Build-Depends:\s*(.*?)(?:\n\S|$)', source_paragraph, re.DOTALL)
        if bd_match:
            bd_str = bd_match.group(1).replace('\n', ' ')
            # Split by comma, remove version constraints and arch restrictions
            deps = bd_str.split(',')
            for dep in deps:
                dep = dep.strip()
                # Remove version constraints like (>= 1.0)
                dep = re.sub(r'\(.*?\)', '', dep)
                # Remove arch restrictions like [amd64] or <!nocheck>
                dep = re.sub(r'\[.*?\]', '', dep)
                dep = re.sub(r'<.*?>', '', dep)
                dep = dep.strip()
                if dep:
                    build_depends.append(dep)

    return source_pkg, binary_pkgs, build_depends

def main():
    repo_to_binaries = {}
    binary_to_repo = {}
    repo_dependencies = defaultdict(set)
    
    repos = [d for d in os.listdir(SOURCES_DIR) if os.path.isdir(os.path.join(SOURCES_DIR, d))]
    
    print(f"Scanning {len(repos)} repositories...", file=sys.stderr)

    # Pass 1: Map Repos to Binary Packages
    for repo in repos:
        repo_path = os.path.join(SOURCES_DIR, repo)
        source_pkg, binary_pkgs, build_deps = parse_control_file(repo_path)
        
        if source_pkg:
            repo_to_binaries[repo] = binary_pkgs
            # Also map the source package name itself, as sometimes build-depends refer to it (though rare for binary deps)
            # Actually Build-Depends refers to binary packages.
            # But sometimes people depend on the source package name if it matches a binary name.
            
            for binary in binary_pkgs:
                binary_to_repo[binary] = repo
            
            # Store build deps for Pass 2
            repo_dependencies[repo] = set(build_deps)
        else:
            # print(f"Skipping {repo}: No debian/control found", file=sys.stderr)
            pass

    # Pass 2: Build Dependency Graph
    graph = defaultdict(set)
    in_degree = defaultdict(int)
    
    # Initialize in_degree for all repos
    for repo in repo_to_binaries:
        in_degree[repo] = 0

    for repo, deps in repo_dependencies.items():
        for dep in deps:
            if dep in binary_to_repo:
                dependency_repo = binary_to_repo[dep]
                if dependency_repo != repo: # Ignore self-dependencies
                    if dependency_repo not in graph[repo]: # repo depends on dependency_repo? No, graph direction.
                        # If A depends on B, we must build B before A.
                        # Edge: B -> A
                        if repo not in graph[dependency_repo]:
                            graph[dependency_repo].add(repo)
                            in_degree[repo] += 1

    # Pass 3: Topological Sort
    queue = deque([r for r in repo_to_binaries if in_degree[r] == 0])
    sorted_repos = []
    
    while queue:
        repo = queue.popleft()
        sorted_repos.append(repo)
        
        for neighbor in graph[repo]:
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    # Check for cycles
    if len(sorted_repos) != len(repo_to_binaries):
        print("WARNING: Circular dependencies detected or disconnected graph components!", file=sys.stderr)
        print(f"Sorted: {len(sorted_repos)}, Total: {len(repo_to_binaries)}", file=sys.stderr)
        
        # Add remaining repos (simple heuristic for now: just append them)
        remaining = [r for r in repo_to_binaries if r not in sorted_repos]
        sorted_repos.extend(remaining)

    # Output sorted list
    for repo in sorted_repos:
        print(repo)

if __name__ == "__main__":
    main()
