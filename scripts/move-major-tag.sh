#!/usr/bin/env bash
# Point the floating major tag (v0, v1, ...) at the release just cut, so
# `uses: camunda/safer-d/.github/workflows/safer-d.yml@v0` follows releases
# within a major. Invoked by @semantic-release/exec successCmd.
set -euo pipefail

VERSION="${1:?usage: move-major-tag.sh <version>}"
MAJOR="v${VERSION%%.*}"

git tag -f "$MAJOR" "v${VERSION}"
git push -f origin "refs/tags/${MAJOR}"
echo "[move-major-tag] ${MAJOR} -> v${VERSION}"
