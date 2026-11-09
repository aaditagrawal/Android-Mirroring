#!/bin/bash
# Check help, tool schemas and MCP framing without launching the app or touching a phone.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/check-cli.swift "${1:-build/Android Mirroring.app/Contents/MacOS/droidctl}"
