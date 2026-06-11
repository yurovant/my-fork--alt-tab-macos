#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

rm -rf \
  DerivedData \
  CompilationCache.noindex \
  Index.noindex \
  Logs \
  ModuleCache.noindex \
  SDKStatCaches.noindex \
  codesign.conf \
  codesign.crt \
  codesign.key \
  codesign.p12
