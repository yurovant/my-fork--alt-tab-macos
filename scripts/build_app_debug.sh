#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

xcodebuild \
  -workspace alt-tab-macos.xcworkspace \
  -scheme Debug \
  -configuration Debug \
  -derivedDataPath DerivedData
