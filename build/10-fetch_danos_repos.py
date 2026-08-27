import urllib.request
import json
import sys

def get_all_repos(org_name):
    repos = []
    page = 1
    while True:
        url = f"https://api.github.com/orgs/{org_name}/repos?per_page=100&page={page}"
        print(f"Fetching page {page}...", file=sys.stderr)
        try:
            req = urllib.request.Request(url)
            # Add User-Agent to avoid 403 Forbidden (GitHub API requires it)
            req.add_header('User-Agent', 'Python-urllib/3.x')
            
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    print(f"Error: Failed to fetch repos. Status code: {response.status}", file=sys.stderr)
                    break
                
                data = json.loads(response.read().decode())
                if not data:
                    break
                
                for repo in data:
                    repos.append(repo['clone_url'])
                
                if len(data) < 100:
                    break
                
                page += 1
        except Exception as e:
            print(f"Exception: {e}", file=sys.stderr)
            break
            
    return repos

if __name__ == "__main__":
    org = "danos"
    all_repos = get_all_repos(org)
    print(f"Found {len(all_repos)} repositories.", file=sys.stderr)
    
    for url in sorted(all_repos):
        print(url)
