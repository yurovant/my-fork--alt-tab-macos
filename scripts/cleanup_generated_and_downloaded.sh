#!/usr/bin/env bash
# fork: removes build output, including stale resources that DerivedData keeps across branch switches, and the
# codesign.* files left by scripts/codesign/setup_local.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

rm -rf \
  DerivedData \
  codesign.conf \
  codesign.crt \
  codesign.key \
  codesign.p12
