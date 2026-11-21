# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

## Role

**safer-d** holds the Safer D rules shared by Camunda's D repos (d8ctl, the D
SDK, nano-coder-d) and the tools that enforce them. The rules and their
rationale are in `SAFER-D.md`. Treat it as the spec: change it in the same PR
as the checker.

## Path map

| Path | Ownership |
| --- | --- |
| `source/safer/` | Library: the safe replacements the rules point to. |
| `source/safer/{io,concurrency,json}.d` | The io modules: the only place `@trusted` is expected. |
| `check/source/safer/check/lexer.d` | Strips comments and literals and keeps string-mixin text. Rules match code, never raw lines. |
| `check/source/safer/check/rules.d` | SD001–SD024 and `projectRules` (P000). |
| `check/source/safer/check/rules_test.d` | One test per rule: a hit and a near miss. |
| `check/source/safer/check/config.d` | `safer-d.json`. |
| `check/source/safer/check/scaffold.d` + `templates/` | `init`. Templates are compiled in (`stringImportPaths`). |
| `check/source/safer/check/version_.d` | Stamped by `scripts/prepare-release.sh`. Don't hand-edit. |
| `.github/workflows/safer-d.yml` | Reusable workflow that other repos call at `@vX`. |
| `scripts/e2e.sh` | `init`, then build, test and a planted violation. |

## Rules for changing rules

- Never reuse or renumber an SD ID.
- A new rule ships as `warn` (in `Config.severity` defaults), becomes an
  error one minor later, and gets a `SAFER-D.md` section and a test in
  `rules_test.d` with a near miss.
- Before changing a rule, run it against nano-coder-d, d8ctl and the D SDK
  (copy `source/` + `dub.json` to `/tmp`, add a `safer-d.json`) and report the
  count changes in the PR.

## Strictness

LDC ≥ 1.43 only. Every module `@safe:`. `-preview=dip1000
-preview=nosharedaccess`. Release keeps `-boundscheck=on`. Phobos only.

## Commands

```bash
make check        # test + self-check + e2e + lint
```
