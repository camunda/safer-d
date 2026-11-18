#!/usr/bin/env bash
# Scaffold a project with `safe-d-check init`, point its safe-d dependency at
# this checkout, and prove the loop: it tests, it runs, and one planted
# violation fails `dub build` through the preBuildCommands hook.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/hello-safe"

"$REPO_ROOT/safe-d-check" init "$APP"
cat > "$APP/dub.selections.json" <<JSON
{
  "fileVersion": 1,
  "versions": {
    "safe-d": {"path": "$REPO_ROOT"}
  }
}
JSON

cd "$APP"
dub test -q
out="$(dub run -q -- e2e)"
[ "$out" = "hello, e2e" ] || { echo "e2e: unexpected output: $out" >&2; exit 1; }

echo 'int planted() { return cast(int) 1.5; }' >> source/hello_safe/greet.d
if dub build -q 2> "$WORK/build.err"; then
    echo "e2e: a planted cast( did not fail the build" >&2
    exit 1
fi
grep -q 'SD020' "$WORK/build.err" || { cat "$WORK/build.err" >&2; echo "e2e: build failed, but not on SD020" >&2; exit 1; }
echo "e2e: ok (init -> test -> run -> violation fails the build)"
