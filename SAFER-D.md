# Safer D

Safer D = [SafeD](https://dlang.org/articles/safed.html) (D's memory-safe
subset: `@safe` everywhere, which SD001–SD003 enforce) plus rules for null,
errors, casts and concurrency. SafeD is the language's term; Safer D is
Camunda's house profile built on it, not a replacement for it.

Safer D is D with the escape hatches counted: what TypeScript's strict mode
and a ban on `any` and casts are to JavaScript. The compiler does most of the
work (`@safe`, DIP1000 scope checking, `nosharedaccess`); `safer-d-check`
enforces the rest, the parts the compiler allows but a reviewer shouldn't
have to catch.

Two kinds of rule:

- **Bans** fail on any occurrence. They cover things with a safe replacement
  in `safer-d` itself.
- **Budgets** cap a count per repo (`safer-d.json` `budgets`, missing = 0).
  They cover escapes that are sometimes right. A budget can only go down
  without review: the checker tells you when the code comes in under it, and
  `--ratchet` lowers it. Raising one is a visible diff in a PR.

Every finding prints as `file(line): Error: SDxxx message`, like a compiler
error, so editors and CI pick it up.

## Why not Rust?

Rust is the reference for "safe and strict": the borrow checker, no null,
exhaustive `match`, `Result` instead of exceptions, `unsafe` blocks that
stand out. Safer D aims for most of that guarantee at a fraction of the build
cost. The trade is deliberate, so here it is in full.

### Safety and correctness

| Concern | Rust | Safer D |
| --- | --- | --- |
| Memory safety | Borrow checker; compile error. | `@safe` + DIP1000 `scope`, with the GC owning heap memory; compile error. Equivalent for use-after-free and out-of-bounds. Both keep bounds checks in release builds. |
| Escape hatches | `unsafe { }`: visible, but not counted (`cargo-geiger` is opt-in). | `@trusted`, `cast`, `assumeIsolated`: each needs a reason (SD006) and counts against a per-repo budget (SD004, SD005, SD009, SD020). **Stricter than stock Rust.** |
| Data races | `Send`/`Sync`; compile error. | `shared` + `nosharedaccess` makes touching shared data directly a compile error. Unshared data crosses threads safely only through `safer.concurrency.spawn` (immutable or `Isolated` arguments). The checker bans raw threads (SD007, SD008); the type system doesn't. **Weaker than Rust**: a lint, not a proof. |
| Aliasing | One `&mut` or many `&`; compile error. | Not checked. Mutable aliasing is memory-safe under the GC, but it allows logic bugs that Rust rules out (mutating a collection while something else reads it). **Weaker than Rust.** |
| Null | No null; `Option<T>`. | Class references can be null. `Option`/`NotNull`, the null-audit unittest (SD018) and budgets on classes, null checks and `Nullable` (SD015–SD017, SD019) shrink it to counted, reviewed places. **Weaker than Rust**: enforced by the checker and a test, not by the types. |
| Exhaustiveness | `match` must be exhaustive. | `final switch` must be, and SD014 bans `default:` in a switch over an enum. `SumType.match` is exhaustive. **Equivalent** once SD014 holds. |
| Errors | `Result` and `?`; panics for bugs. | `safer.result.Result!(T, E)` is `@mustuse` (ignoring one is a compile error) and its value is reachable only through accessors that handle the error. With `nothrow`, the signature says what can fail. `?` is a two-word idiom (`foreach (e; r.take(v)) return typeof(return).err(e);`), not an operator. Code that still throws is held by SD012/SD013. **Close to Rust** where `Result` + `nothrow` are used; weaker where exceptions remain. |
| Unsigned underflow | Panics in debug builds; wraps in release by default. | Wraps. `saturatingSub` and `checkedSub` (which halts), plus SD010/SD011 in the modules where it matters. **About equal**: in both, release builds are safe only where the code chose checked arithmetic. |
| Casts | `as` truncates silently; `From`/`TryFrom` are checked. | `cast(` is budgeted (SD020); `std.conv.to` is checked. **Stricter than stock Rust**, which doesn't count `as`. |

In short, Safer D is:
- **Equal** on memory safety and exhaustiveness.
- **Stricter** on counting escape hatches.
- **Weaker** on aliasing, data races outside `safer.concurrency`, null, and
  errors in signatures where code still throws instead of returning a `Result`. There the checker and its budgets do work that
  Rust's types do.

The gap is real. The budgets keep it visible and shrinking.

### Build time and disk

These numbers compare the same program in both languages: nano-coder (Rust:
72,360 lines plus 288 crates in `Cargo.lock`) and nano-coder-d, its D port
(52,806 lines, Phobos only). Measured on an Apple M4 Pro, with dependencies
already downloaded.

| | Rust (cargo 1.100) | D (LDC 1.43, dub) |
| --- | --- | --- |
| Clean debug build | 31.0 s | 6.8 s |
| Clean release build | 74.5 s | 18.3 s |
| Rebuild after touching one file | **2.6 s** (incremental) | 6.7 s (dub rebuilds the whole package) |
| Build output per configuration, debug | 1.1 GB (`target/debug`) | 22 MB (`~/.dub/cache`) |
| Build output per configuration, release | 387 MB (`target/release`) | 13 MB |
| Release binary | 6.0 MB | 4.9 MB |
| Toolchain on disk | 0.6–1.3 GB per Rust version | 98 MB (LDC) + 9 MB (dub) |
| Dependency cache | 1.0 GB (`~/.cargo/registry`) | 76 MB (`~/.dub/packages`) |

What the numbers show:
- **Clean builds are 4–5x faster in D.** That matters for CI, for agent
  workers that build from a fresh checkout, and for machines that host many
  checkouts.
- **Build output is 30–50x smaller per configuration**, and the toolchain
  about a tenth the size.
- **dub never prunes its cache.** nano-coder-d's has built up 85
  configurations (1.5 GB); clear `~/.dub/cache` now and then.
- **Rust wins the edit-and-rebuild loop.** cargo compiles incrementally and
  dub doesn't, so a one-file change rebuilds faster in Rust. D's full rebuild
  of this program still takes under 7 seconds.

## The compiler settings (SD021)

Every `dub.json` package (root and subpackages) has:

| Setting | Why |
| --- | --- |
| `toolchainRequirements`: `ldc >=1.43.0`, `dmd: no`, `gdc: no` | One compiler, one set of diagnostics. |
| `-preview=dip1000` | `scope` is checked: no reference outlives what it points into. |
| `-preview=nosharedaccess` | `shared` data is only touched through atomics or a lock. |
| `dflags-ldc: -fno-delete-null-pointer-checks` | A null dereference traps instead of being optimised into anything. |
| release `dflags-ldc: -boundscheck=on` | Release builds keep bounds checks: `@safe` relies on them. |
| root `preBuildCommands` runs safer-d-check | Every build is checked, not only CI. |

The hook `safer-d-check init` writes:

```json
"preBuildCommands": ["dub run -q --root \"$SAFER_D_PACKAGE_DIR\" :check -- --root \"$PACKAGE_DIR\""]
```

dub sets `$SAFER_D_PACKAGE_DIR` to the safer-d the project depends on, so the
checker is always that version: no registry lookup, no drift between the
rules and the library that answers them.

## Rules

| ID | Kind | Rule |
| --- | --- | --- |
| SD001 | ban | Every module has a module-level `@safe:`. |
| SD002 | ban | No `@system:` or `@trusted:` labels. |
| SD003 | ban | `@system` only on `extern (C)` declarations. |
| SD004 | budget `trusted` | `@trusted` outside the io modules. |
| SD005 | budget `trusted-io` | `@trusted` inside the io modules. |
| SD006 | ban | A comment directly above every `@trusted` and `assumeIsolated` says why it is safe. |
| SD007 | ban | No raw threads outside the io modules. |
| SD008 | ban | No `__gshared` or `union` outside the io modules. |
| SD009 | budget `isolation` | `assumeIsolated` outside the io modules. |
| SD010 | ban | No hand-written `a > b ? a - b : 0`. |
| SD011 | budget `subtraction` | Raw subtractions in the `subtractionScope` modules. |
| SD012 | ban | A `catch (Exception)` that swallows says why; never catch `Throwable` or `Error`. |
| SD013 | budget `catch` | `catch (Exception)` outside test files. |
| SD014 | ban | A `switch` over an enum is a `final switch`. |
| SD015 | budget `class-null` | Null checks on class references. |
| SD016 | budget `nullable` | `Nullable!` uses. |
| SD017 | budget `class` | Class declarations (exceptions aside). |
| SD018 | ban | The null-audit module imports every module. |
| SD019 | budget `nullable-mark` | `@nullable("why")` marks. |
| SD020 | budget `cast` | `cast(` outside the io modules. |
| SD021 | ban | `dub.json` keeps the compiler settings above. |
| SD022 | budget `null-local` | Class-typed locals that start or become null. |
| SD023 | budget `pure-throw` | `throw`s in pure-core modules; their exception classes are private. |
| SD024 | ban | No module-level `version (unittest)` imports outside test-only modules. |

### SD001–SD003: `@safe` everywhere

`@safe:` at the top of every module makes memory safety the default; the
compiler then rejects pointer arithmetic, unchecked casts and calls into
`@system` code. `@system:` and `@trusted:` labels would turn that off for the
rest of a module without anyone seeing it, so they are banned. `@system` is
only for declaring C functions; their callers wrap them in `@trusted`.

### SD004–SD006: `@trusted` is a reviewed promise

`@trusted` tells the compiler "I checked this by hand". Each one is a place
the compiler stopped looking, so each needs a reason (SD006: a comment
directly above, or above the first line of a wrapped signature) and each
counts.

The **io modules** (`safer-d.json` `ioModules`) are where a project keeps the
wrappers around C, the OS and Phobos' `@system` corners: `safer.io`,
`safer.concurrency` and `safer.json` in this repo, a project's own
`safeio.d` elsewhere. They get their own budget (SD005) because escapes there
are expected and reviewed together; anywhere else (SD004) an escape is a
smell, usually fixed by moving the wrapper into an io module.

Text inside `mixin("...")` counts as code for these rules, and for SD002,
SD003, SD007–SD009 and SD020: a string mixin can't hide an escape.

### SD007–SD009: threads go through `safer.concurrency`

`new Thread`, `std.concurrency` and `__gshared` let two threads see the same
mutable data with no type telling you so. `safer.concurrency` offers
`spawn`/`spawnDaemon` (only `Isolated` or immutable arguments cross),
`Locked!T`, `Shared!T` and `Chan!T` instead, all `@safe`. `union` is banned
for the same reason as a cast: it reinterprets memory. `assumeIsolated`
(SD009) asserts that nothing else holds a reference; it is counted and needs
a reason, like `@trusted`.

### SD010–SD011: unsigned subtraction

`size_t` subtraction wraps silently: `0 - 1` is 18 quintillion.
`safer.arith.saturatingSub(a, b)` stops at zero and `checkedSub` halts on underflow (as `checkedAdd`/`checkedMul` do on overflow); the
hand-written `a > b ? a - b : 0` (SD010) is banned because the next edit
flips one side. SD011 counts raw `a - b` in the modules listed in
`subtractionScope`: the ones where a wrapped length or offset is a real bug
(budgets, windows, offsets). `$ - 1` and negative literals don't count.

### SD012–SD013: no silent catches

A `catch (Exception)` that neither uses the exception nor rethrows hides
failures (SD012); give the reason in a `//` comment on or above it.
`Throwable` and `Error` are never caught: they mean the program is broken
(an assert, a range error, out of memory), and carrying on is unsafe. The
catch budget (SD013) keeps error handling on the explicit path: return types,
`Option`, `SumType`.

#### `Result` instead of exceptions

`safer.result.Result!(T, E)` is Rust's `Result`. A function that can fail
returns one and is marked `nothrow`, so its signature lists everything that
can go wrong:

```d
import safer.result;

Result!(Config, string) load(string path) nothrow
{
    string text;
    foreach (e; readFile(path).take(text)) return typeof(return).err(e); // `?`
    return parseConfig(text);
}

load(path).match!(
    cfg => run(cfg),
    e => report(e),
);
```

- `@mustuse`: calling `load(path);` without using the value is a compile
  error. `cast(void) load(path);` discards it on purpose, and SD020 counts it.
- The value is private. `match` (both cases), `take` (`?`), `foreach (v; r)`
  (`if let Ok`), `map`, `mapErr`, `andThen`, `orElse`, `okOption` and
  `errOption` all make you handle the error or say you're dropping it.
  `unwrap("why")` halts with the reason.
- `attempt!f(args)` runs throwing code (Phobos, a library) and returns a
  `Result!(R, Exception)`, so the throw stops at the edge of your code.
- No success value: `Result!(None, E)` with `typeof(return).ok(none)`.
- What D can't do: `?` is an idiom, not an operator, and errors don't convert
  between types implicitly (Rust's `From`). Convert in the `take` body.

### SD014: `final switch` over enums

A `final switch` fails to compile when someone adds an enum member, so the
compiler finds every place to update. `default:` makes the new member fall
through silently. List the skipped members as empty cases instead.

### SD015–SD019: no null

A class reference can be null, and D won't stop you dereferencing it.
`safer.option.Option!T` is the type for "maybe absent"; it is read with
`foreach (x; opt)`, so there is no unwrap to forget, and `some(null)` halts
at the point of the mistake rather than later. `NotNull!T` carries a class
reference that has been checked.

- SD015 counts null checks on class references: each is a place where the
  type should have been `Option`.
- SD016 counts `Nullable!`, which has `.get` that throws, the same trap.
- SD017 counts classes. Prefer a struct, an enum or a `SumType`; a class is
  for reference identity or inheritance, and every class reference can be
  null. Exceptions don't count.
- SD018 and SD019: `safer.nullaudit.auditModules!(...)` fails a unittest when
  any field or global is a bare class reference (not `Option`, `NotNull` or
  marked `@nullable("why")`). SD018 makes sure the audit module imports every
  module, so a new one can't skip it; SD019 counts the marks.
- SD022 counts the ways a class-typed local in a function body becomes
  null: `C c;` without an initialiser, `C c = null;`, `c = null;`, and
  `null` as a branch of a `?:` it is set from. Initialise the local where
  it is declared, from `new` or a call, or use `Option!C` when absence is
  real. Then the local can't be dereferenced while null. A type-aware
  analysis that proved each dereference was spiked
  ([safer-d#3](https://github.com/camunda/safer-d/issues/3)): it caught one
  more case (a dereference inside an `is null` branch) at 100–280 MB a
  file. Banning the pattern costs nothing. The rule reads text, so an
  `auto` local counts only when its non-null branch is visibly a class
  (`new C`, or a known class-typed local or parameter). Test files and
  `unittest` blocks don't count.

### SD023: pure-core errors are values

A pure-core module is one with a `pure:` label: every free function in it
depends only on its arguments. In such a module a failure is a value, a
`Result` from `safer.result`, so the signature says what can go wrong. The
one throw that stays is a parser unwinding to its own entry point, which
catches it and returns the error result. Its exception class is `private`,
so the exception can't escape the module, and SD023 counts the `throw`s
against the `pure-throw` budget. A public exception class in a pure-core
module is an error.

### SD024: test-only imports stay in the tests

A module-level `version (unittest) import x;` (or an import directly inside a
module-level `version (unittest) { ... }` block) is in scope for the whole
module, but only in the test build. Non-test code that uses it by mistake
passes `dub test` and breaks the release build. Put the import in the
`unittest` block or the test helper that uses it. A module that is test-only
from the top (`version (unittest):`) is exempt.

### SD020: casts

`cast(` is D's `as any`: it overrides the type system, and in `@safe` code
the compiler only rejects the most dangerous ones. Use `std.conv.to` (checked: it throws when a value doesn't fit) for
conversions, and a typed function for the rest. Casts in the io modules don't count; generated code can be
exempted with `allow`.

## safer-d.json

```json
{
  "sources": ["source"],
  "exclude": [],
  "ioModules": ["source/app/safeio.d"],
  "testFiles": ["*_test.d"],
  "subtractionScope": ["source/app/budget.d"],
  "nullAudit": { "module": "source/app/null_audit_test.d", "skip": ["source/app.d"] },
  "allow": { "SD020": ["source/app/generated"] },
  "rules": { "SD020": "warn" },
  "budgets": { "trusted-io": 12, "catch": 3 },
  "dubFiles": ["dub.json"],
  "requireHook": true,
  "projectRules": [
    { "id": "P001", "kind": "ban", "pattern": "\\bsetlocale\\b", "message": "keep the C locale" }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `sources` | Directories (or files) to check. |
| `exclude` | Paths to skip, with everything under them. |
| `ioModules` | Files where `@trusted`, threads, `__gshared` and casts are expected. |
| `testFiles` | Globs for test files: exempt from SD012, SD013, SD016, SD017 and SD020. |
| `subtractionScope` | Files where SD011 counts raw subtractions. |
| `nullAudit` | The module that runs `auditModules`; `skip` lists modules it can't import. Omit to turn SD018 off. |
| `allow` | Rule ID to paths where that rule doesn't apply. |
| `rules` | Rule ID to `off` or `warn` (default: error; a new rule defaults to warn for one minor release). |
| `budgets` | Budget name to the most allowed. Missing means 0. |
| `dubFiles` | `dub.json` files SD021 checks. |
| `requireHook` | Whether SD021 requires the build hook (off only for safer-d itself). |
| `projectRules` | The project's own checks (below). |

Unknown keys are an error, so a typo can't switch a rule off.

### Project rules

Some checks matter to one project only: "only `clock.d` reads the clock",
"every pure-core module is listed in the purity audit". `projectRules` lets
a project declare them in `safer-d.json` instead of a side script.

```json
"projectRules": [
  { "id": "P001", "kind": "ban", "pattern": "\\bClock\\.curr(Std)?Time\\b|\\bThread\\.sleep\\b",
    "except": ["source/app/clock.d"], "message": "read the clock and sleep through app.clock so tests can fake time" },
  { "id": "P002", "kind": "budget", "pattern": "\\bgetenv\\b", "budget": "getenv", "message": "`getenv` calls" },
  { "id": "P003", "kind": "floor", "pattern": "\\bpure\\b(?!:)", "floor": 1213, "message": "`pure` attributes" },
  { "id": "P004", "kind": "listed", "select": "^pure:\\s*$", "listIn": "source/app/pure_core_test.d",
    "exact": true, "message": "every pure-core module is listed in pure_core_test.d" }
]
```

| Kind | Meaning |
| --- | --- |
| `ban` | Each match of `pattern` is a finding. |
| `budget` | Matches are counted against `budgets[budget]`. `--ratchet` lowers it. |
| `floor` | Matches are counted and may only go up: below `floor` is an error, and `--ratchet` raises it. |
| `listed` | Every module with a line matching `select` is `import`ed or `static import`ed by `listIn` (SD018's mechanism, generalised). With `exact`, every `static import` in `listIn` must name such a module too. |

- Patterns are `std.regex` and match each line's code: comments are removed
  and string contents emptied, as for the SD rules. Each match counts, so a
  line with two hits counts two.
- Every kind takes `except` and `only` (path lists) and `testFiles` (whether
  test files count; default `false`).
- IDs are `P` and three digits, so they can't clash with an SD ID. `allow` and
  `rules` take them like SD IDs.
- `adopt` doesn't write project rules, but it sets `budget` and `floor`
  rules to today's counts.
- Unknown kinds or keys, keys of another kind, bad regexes and duplicate IDs
  are errors.

A project rule is for a local convention: a module that owns the clock, a
call the project bans for its own reasons. When the reason is about D itself
(memory safety, absence, error handling) and would hold in any Safer D
project, propose it here as an SD rule instead, as SD023 and SD024 were.

## Adopting

```bash
dub add safer-d
dub run safer-d:check -- adopt     # writes safer-d.json, budgets at today's counts
```

Then add the hook and CI (see the README). From then on a count can only go
down. `adopt` on an existing `safer-d.json` keeps your settings and rewrites
only the budgets.

## Versioning the rules

- A rule ID is never reused or renumbered.
- A new rule ships as `warn` in a minor release and becomes an error in the
  next minor, so a dependency bump never breaks a build without notice. Pin
  with `~>` in `dub.json`; `adopt` after a bump sets budgets for new counts.
- Bug fixes that catch more (as when string mixins started counting) are
  minor releases, with the change in the release notes.
