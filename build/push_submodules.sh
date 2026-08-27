#!/bin/bash
set -e
cd /build-iso/danos-sources
for dir in */; do
    repo=${dir%/}
    echo "Processing $repo"
    # Create repo
    if ! gh repo view Aikonlee/$repo >/dev/null 2>gh repo create Aikonlee/$repo --public --confirm || echo "Repo $repo may already exist"1; then gh repo create Aikonlee/$repo --public; else echo "Repo $repo already exists"; fi
    cd $dir
    # Check tag
    if git tag | grep -q '^danos/2110a$'; then
        git checkout danos/2110a
        echo "Checked out tag danos/2110a for $repo"
    else
        echo "Tag danos/2110a not found for $repo, staying on current"
    fi
    # Create branch
    git checkout -B feature-updates
    # Add remote
    git remote add origin https://github.com/Aikonlee/$repo.git 2>/dev/null || echo "Remote already exists"
    # Push
    git push -u origin feature-updates
    cd ..
done
