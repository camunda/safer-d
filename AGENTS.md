# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

## Role

**safe-d** holds the Safe D rules shared by Camunda's D repos (d8ctl, the D
SDK, nano-coder-d) and the tools that enforce them. The rules and their
rationale are in `SAFE-D.md`. Treat it as the spec: change it in the same PR
as the checker.

## Path map

| Path | Ownership |
| --- | --- |
| `source/safed/` | Library: the safe replacements the rules point to. |
| `source/safed/{io,concurrency,json}.d` | The io modules: the only place `@trusted` is expected. |
| `check/source/safed/check/lexer.d` | Strips comments and literals and keeps string-mixin text. Rules match code, never raw lines. |
| `check/source/safed/check/rules.d` | SD001–SD024 and `projectRules` (P000). |
| `check/source/safed/check/rules_test.d` | One test per rule: a hit and a near miss. |
| `check/source/safed/check/config.d` | `safe-d.json`. |
| `check/source/safed/check/scaffold.d` + `templates/` | `init`. Templates are compiled in (`stringImportPaths`). |
| `check/source/safed/check/version_.d` | Stamped by `scripts/prepare-release.sh`. Don't hand-edit. |
| `.github/workflows/safe-d.yml` | Reusable workflow that other repos call at `@vX`. |
| `scripts/e2e.sh` | `init`, then build, test and a planted violation. |

## Rules for changing rules

- Never reuse or renumber an SD ID.
- A new rule ships as `warn` (in `Config.severity` defaults), becomes an
  error one minor later, and gets a `SAFE-D.md` section and a test in
  `rules_test.d` with a near miss.
- Before changing a rule, run it against nano-coder-d, d8ctl and the D SDK
  (copy `source/` + `dub.json` to `/tmp`, add a `safe-d.json`) and report the
  count changes in the PR.

## Strictness

LDC ≥ 1.43 only. Every module `@safe:`. `-preview=dip1000
-preview=nosharedaccess`. Release keeps `-boundscheck=on`. Phobos only.

## Commands

```bash
make check        # test + self-check + e2e + lint
```
