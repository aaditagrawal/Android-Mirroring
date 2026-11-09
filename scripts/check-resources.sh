#!/bin/bash
# Verify the exact Android payloads distributed with the app.
set -euo pipefail
cd "$(dirname "$0")/../Resources"
shasum -a 256 -c SHA256SUMS
