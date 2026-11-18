# safe-d

The shared Safe D rules for Camunda's D projects, and the tools that hold a
repo to them. Safe D is D with every escape hatch (`@trusted`, casts, null,
raw threads, silent catches) either banned or counted: the TypeScript-strict
idea, at D's compile times. [SAFE-D.md](SAFE-D.md) has the rules and why,
and [how Safe D compares with Rust](SAFE-D.md#why-not-rust) on safety and on
build time and disk (clean builds 4–5x faster, build output 30–50x smaller).

One dub package, two parts:

| Part | What |
| --- | --- |
| `safe-d` (library) | The safe replacements the rules point to: `safed.option` (`Option`, `NotNull`), `safed.arith` (`saturatingSub`, `checkedSub`/`Add`/`Mul`), `safed.nullaudit`, `safed.concurrency` (`spawn`, `Locked`, `Chan`), `safed.io`, `safed.json`. Phobos only, all `@safe`. |
| `safe-d:check` | `safe-d-check`: checks a project (SD001–SD021), measures one (`adopt`), creates one (`init`). |

Seeded from nano-coder-d's `check-safe.sh`, the strictest of the set, and
checked against it: on nano-coder-d, d8ctl and the D SDK, every existing
rule gives the same counts as the scripts it replaces.

## New project

```bash
dub run safe-d:check -- init my-tool
cd my-tool && dub test && dub run
```

This gives you `dub.json` with the Safe D compiler settings and the build
hook, `safe-d.json` with zero budgets, a module showing the style, the null
audit, a Makefile and a CI workflow.

## Existing project

```bash
dub add safe-d
dub run safe-d:check -- adopt        # safe-d.json with budgets at today's counts
```

Then edit `safe-d.json` (`ioModules` for your `safeio.d`, `nullAudit` for your
audit test) and run `adopt` again. Then add the build hook to `dub.json`:

```json
"preBuildCommands": ["dub run -q --root \"$SAFE_D_PACKAGE_DIR\" :check -- --root \"$PACKAGE_DIR\""]
```

and CI:

```yaml
jobs:
  safe-d:
    uses: camunda/safe-d/.github/workflows/safe-d.yml@v0
    with:
      apt-packages: libcurl4-openssl-dev zlib1g-dev   # if you link curl
```

From then on the counts only go down: the checker tells you when one
comes in under its budget, and `safe-d-check --ratchet` lowers it.

## safe-d-check

```
safe-d-check [check] [--root DIR] [--format text|github] [--ratchet]
safe-d-check adopt [--root DIR]
safe-d-check init DIR [--name NAME]
safe-d-check rules
```

Findings print like compiler errors (`file(line): Error: SD012 ...`);
`--format github` prints them as workflow annotations.

## Developing

LDC ≥ 1.43, dub. safe-d holds itself to its own rules (`safe-d.json`).

```bash
make test         # unittests: library + checker (one test per rule)
make self-check   # safe-d-check on this repo
make e2e          # init a project, build it, prove a violation fails the build
make lint         # D-Scanner
make check        # all of the above
```

Releases: conventional commits on `main` make semantic-release tag `vX.Y.Z`,
which code.dlang.org picks up. The `vX` tag moves along with each release,
for the reusable workflow.
