#!/bin/bash
# Signs a runs-on-vz binary ad hoc with the virtualization entitlement, which
# Virtualization.framework requires of its caller, and checks the result.
# An ad hoc signature needs no certificate and travels with the binary.
set -euo pipefail
binary="${1:?usage: Scripts/sign.sh BINARY}"
cd "$(dirname "$0")/.."
codesign --force --sign - --entitlements runs-on-vz.entitlements "$binary"
codesign --verify --strict "$binary"
entitlements="$(codesign --display --entitlements - "$binary" 2>/dev/null)"
grep -q com.apple.security.virtualization <<<"$entitlements"
