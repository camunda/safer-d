#!/usr/bin/env bash
# Scaffold a project with `safer-d-check init`, point its safer-d dependency at
# this checkout, and prove the loop: it tests, it runs, and one planted
# violation fails `dub build` through the preBuildCommands hook.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Git Bash on Windows spells paths /d/a/...; dub (a native program) needs
# D:/a/... in the selections file.
if command -v cygpath > /dev/null; then REPO_ROOT_NATIVE="$(cygpath -m "$REPO_ROOT")"; else REPO_ROOT_NATIVE="$REPO_ROOT"; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/hello-safe"

"$REPO_ROOT/safer-d-check" init "$APP"
cat > "$APP/dub.selections.json" <<JSON
{
  "fileVersion": 1,
  "versions": {
    "safer-d": {"path": "$REPO_ROOT_NATIVE"}
  }
}
JSON

cd "$APP"
dub test -q
out="$(dub run -q -- e2e)"
out="${out%$'\r'}"  # Windows writeln emits CRLF
[ "$out" = "hello, e2e" ] || { echo "e2e: unexpected output: $out" >&2; exit 1; }

echo 'int planted() { return cast(int) 1.5; }' >> source/hello_safe/greet.d
if dub build -q 2> "$WORK/build.err"; then
    echo "e2e: a planted cast( did not fail the build" >&2
    exit 1
fi
grep -q 'SD020' "$WORK/build.err" || { cat "$WORK/build.err" >&2; echo "e2e: build failed, but not on SD020" >&2; exit 1; }

# Pre-2.0 config name: still read with a warning; adopt migrates it.
mv safer-d.json safe-d.json
"$REPO_ROOT/safer-d-check" --root . > /dev/null 2> "$WORK/legacy.err" || true
grep -q 'reading safe-d.json' "$WORK/legacy.err" || { cat "$WORK/legacy.err" >&2; echo "e2e: legacy safe-d.json not read with a warning" >&2; exit 1; }
"$REPO_ROOT/safer-d-check" adopt --root . 2> "$WORK/adopt.err"
[ -e safer-d.json ] || { echo "e2e: adopt did not write safer-d.json" >&2; exit 1; }
grep -q 'delete safe-d.json' "$WORK/adopt.err" || { cat "$WORK/adopt.err" >&2; echo "e2e: adopt did not say to delete safe-d.json" >&2; exit 1; }
echo "e2e: ok (init -> test -> run -> violation fails the build -> legacy config)"
