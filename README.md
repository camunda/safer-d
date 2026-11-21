# safer-d

The shared Safer D rules for Camunda's D projects, and the tools that hold a
repo to them. Safer D is D with every escape hatch (`@trusted`, casts, null,
raw threads, silent catches) either banned or counted: the TypeScript-strict
idea, at D's compile times. [SAFER-D.md](SAFER-D.md) has the rules and why,
and [how Safer D compares with Rust](SAFER-D.md#why-not-rust) on safety and on
build time and disk (clean builds 4–5x faster, build output 30–50x smaller).

Safer D builds on [SafeD](https://dlang.org/articles/safed.html), D's own
name for its memory-safe `@safe` subset: SafeD is the floor, Safer D adds the
rules for null, errors, casts and concurrency on top.

One dub package, two parts:

| Part | What |
| --- | --- |
| `safer-d` (library) | The safe replacements the rules point to: `safer.option` (`Option`, `NotNull`), `safer.result` (`Result`, `attempt`), `safer.arith` (`saturatingSub`, `checkedSub`/`Add`/`Mul`), `safer.nullaudit`, `safer.concurrency` (`spawn`, `Locked`, `Chan`), `safer.io`, `safer.json`. Phobos only, all `@safe`. |
| `safer-d:check` | `safer-d-check`: checks a project (SD001–SD024, plus `projectRules`), measures one (`adopt`), creates one (`init`). |

Seeded from nano-coder-d's `check-safe.sh`, the strictest of the set, and
checked against it: on nano-coder-d, d8ctl and the D SDK, every existing
rule gives the same counts as the scripts it replaces.

## New project

```bash
dub run safer-d:check -- init my-tool
cd my-tool && dub test && dub run
```

This gives you `dub.json` with the Safer D compiler settings and the build
hook, `safer-d.json` with zero budgets, a module showing the style, the null
audit, a Makefile and a CI workflow.

## Existing project

```bash
dub add safer-d
dub run safer-d:check -- adopt        # safer-d.json with budgets at today's counts
```

Then edit `safer-d.json` (`ioModules` for your `safeio.d`, `nullAudit` for your
audit test) and run `adopt` again. Then add the build hook to `dub.json`:

```json
"preBuildCommands": ["dub run -q --root \"$SAFER_D_PACKAGE_DIR\" :check -- --root \"$PACKAGE_DIR\""]
```

and CI:

```yaml
jobs:
  safer-d:
    uses: camunda/safer-d/.github/workflows/safer-d.yml@v2
    with:
      apt-packages: libcurl4-openssl-dev zlib1g-dev   # if you link curl
```

From then on the counts only go down: the checker tells you when one
comes in under its budget, and `safer-d-check --ratchet` lowers it.

## Moving from safe-d (1.x)

2.0 renamed the project from safe-d. Rule ids (SD001…) and config keys are
unchanged.

| 1.x | 2.0 |
| --- | --- |
| dub package `safe-d`, `safe-d:check` | `safer-d`, `safer-d:check` |
| `import safed.option;` (and every `safed.*`) | `import safer.option;` (`safer.*`) |
| `safe-d-check` | `safer-d-check` |
| `safe-d.json` | `safer-d.json` (`safe-d.json` is still read, with a warning, until 3.0; `safer-d-check adopt` writes the new name) |
| `$SAFE_D_PACKAGE_DIR` in `preBuildCommands` | `$SAFER_D_PACKAGE_DIR` |
| reusable workflow `camunda/safe-d/.github/workflows/safe-d.yml@v1` | `camunda/safer-d/.github/workflows/safer-d.yml@v2` |
| SAFE-D.md | SAFER-D.md |

## safer-d-check

```
safer-d-check [check] [--root DIR] [--format text|github] [--ratchet]
safer-d-check adopt [--root DIR]
safer-d-check init DIR [--name NAME]
safer-d-check rules
```

Findings print like compiler errors (`file(line): Error: SD012 ...`);
`--format github` prints them as workflow annotations.

## Developing

LDC ≥ 1.43, dub. safer-d holds itself to its own rules (`safer-d.json`).

```bash
make test         # unittests: library + checker (one test per rule)
make self-check   # safer-d-check on this repo
make e2e          # init a project, build it, prove a violation fails the build
make lint         # D-Scanner
make check        # all of the above
```

Releases: conventional commits on `main` make semantic-release tag `vX.Y.Z`,
which code.dlang.org picks up. The `vX` tag moves along with each release,
for the reusable workflow.
