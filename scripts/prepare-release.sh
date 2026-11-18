#!/usr/bin/env bash
# Stamp the semantic-release-resolved version into the checker, so `init`
# scaffolds projects that depend on this release (`~>X.Y.Z`) and call the
# reusable workflow at `@vX`. Invoked by @semantic-release/exec prepareCmd.
# dub.json carries no version: code.dlang.org reads it from the git tag.
set -euo pipefail

VERSION="${1:?usage: prepare-release.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cat > "$REPO_ROOT/check/source/safed/check/version_.d" <<D
/// The tool's version, stamped by scripts/prepare-release.sh at release.
module safed.check.version_;

@safe:

/// SemVer of this safe-d release.
enum toolVersion = "${VERSION}";
D

echo "[prepare-release] Wrote version ${VERSION} to check/source/safed/check/version_.d"
