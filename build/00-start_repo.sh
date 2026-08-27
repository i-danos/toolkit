#!/bin/bash
REPO_DIR="/build-iso/danos-build/local-repo"
PORT=8080

# Start HTTP server
echo "Starting HTTP server on port $PORT serving $REPO_DIR"
cd "$REPO_DIR" && nohup python3 -m http.server $PORT > /tmp/repo_server.log 2>&1 &
