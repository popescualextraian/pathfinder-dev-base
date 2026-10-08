#!/usr/bin/env bash
# A worker adapter that reports what it was given.
echo "FAKE-WORKER project=$(jq -r .project "$HOME/.agentic/config.json") args=$*"
