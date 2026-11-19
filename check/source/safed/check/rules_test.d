/// One test per rule: a snippet that must trip it and a near miss that
/// must not (often the same text in a comment or a string, which the old
/// grep-based scripts couldn't tell apart).
module safed.check.rules_test;

@safe:

import safed.check.config : Config, parseConfig;
import safed.check.rules;

private Result check(string cfgJson, string[2][] files, string[string] dub = null)
{
    auto cfg = parseConfig(cfgJson);
    Source[] srcs;
    foreach (f; files) srcs ~= source(f[0], f[1]);
    return runRules(cfg, srcs, dub);
}

private Result check(string[2][] files) { return check(`{}`, files); }

/// "SD012@3" for each finding, in order.
private string[] ids(const Result r, string only = null)
{
    import std.conv : to;
    string[] out_;
    foreach (f; r.findings)
        if (!only.length || f.rule == only) out_ ~= f.rule ~ "@" ~ f.line.to!string;
    return out_;
}

private long countOf(const Result r, string rule)
{
    foreach (c; r.counts)
        if (c.rule == rule) return c.count;
    return -1;
}

enum ok = "@safe:\n";

unittest // SD001
{
    assert(ids(check([["a.d", "module a;\nvoid f() {}\n"]]), "SD001") == ["SD001@1"]);
    assert(ids(check([["a.d", "module a;\n// @safe:\n"]]), "SD001") == ["SD001@1"]);
    assert(ids(check([["a.d", "module a;\n@safe:\n"]]), "SD001") == []);
}

unittest // SD002, SD003
{
    auto r = check([["a.d", ok ~ "@trusted:\nvoid g() @system {}\nextern (C) void h() @system;\n// @system here\n"]]);
    assert(ids(r, "SD002") == ["SD002@2"]);
    assert(ids(r, "SD003") == ["SD003@3"]);
}

unittest // SD004, SD005: counted inside and outside the io modules
{
    auto r = check(`{"ioModules":["io.d"]}`, [
        ["a.d", ok ~ "// why\nvoid f() @trusted {}\n/* @trusted */\nauto s = \"@trusted\";\n"],
        ["io.d", ok ~ "// why\nvoid g() @trusted {}\n// why\nvoid h() @trusted {}\n"]]);
    assert(countOf(r, "SD004") == 1 && countOf(r, "SD005") == 2);
}

unittest // SD006
{
    auto r = check(`{"ioModules":["io.d"]}`, [
        ["a.d", ok ~ "void f() @trusted {}\n/// Safe: reads only.\nvoid g() @trusted {}\n"
            ~ "void k() {}\nauto x = Isolated!int.assumeIsolated(1);\n"],
        ["io.d", ok ~ "void h() {}\nauto y = Isolated!int.assumeIsolated(1);\n"]]);
    assert(ids(r, "SD006") == ["SD006@2", "SD006@6"], ids(r, "SD006")[0]);
    // A wrapped signature: the comment sits above its first line.
    auto w = check([["b.d", ok ~ "// why\nvoid f(int a,\n    int b) @trusted\n{\n}\n"]]);
    assert(ids(w, "SD006") == []);
}

unittest // SD007, SD008: banned outside the io modules only
{
    auto r = check(`{"ioModules":["io.d"]}`, [
        ["a.d", ok ~ "auto t = new Thread(&f);\nimport std.concurrency;\n__gshared int x;\nunion U { int a; }\n"
            ~ "// new Thread\nauto s = \"__gshared\";\nint reunion;\n"],
        ["io.d", ok ~ "__gshared int y;\nauto t = new Thread(&f);\n"]]);
    assert(ids(r, "SD007") == ["SD007@2", "SD007@3"]);
    assert(ids(r, "SD008") == ["SD008@4", "SD008@5"]);
}

unittest // SD009
{
    auto r = check([["a.d", ok ~ "// why\nauto x = Isolated!int.assumeIsolated(1);\n// assumeIsolated(\n"]]);
    assert(countOf(r, "SD009") == 1);
}

unittest // SD010
{
    auto r = check(`{"allow":{"SD010":["arith.d"]}}`, [
        ["a.d", ok ~ "auto x = a > b ? a - b : 0;\nauto y = n >= m ? n - m : 0;\nauto z = a > b ? b - a : 0;\n"],
        ["arith.d", ok ~ "return x > y ? x - y : 0;\n"]]);
    assert(ids(r, "SD010") == ["SD010@2", "SD010@3"]);
}

unittest // SD011: only in the listed modules; `$ - 1` doesn't count
{
    auto r = check(`{"subtractionScope":["budget.d"]}`, [
        ["budget.d", ok ~ "auto left = window - used;\nauto last = xs[$ - 1];\nauto n = f(a) - (b);\nint neg = -1;\n"],
        ["other.d", ok ~ "auto d = a - b;\n"]]);
    assert(countOf(r, "SD011") == 2);
}

unittest // SD012
{
    auto r = check([["a.d", ok
        ~ "void f() {\n"
        ~ "    try g(); catch (Exception) {}\n"                 // 3: swallows, no comment
        ~ "    try g(); catch (Exception e) { log(e.msg); }\n"  // 4: uses e
        ~ "    try g(); catch (Exception) {} // best effort\n"  // 5: says why
        ~ "    try g();\n"
        ~ "    catch (Exception e)\n"                           // 7: multi-line, rethrows
        ~ "    {\n"
        ~ "        throw new Wrapped(e.msg);\n"
        ~ "    }\n"
        ~ "    try g(); catch (Throwable t) {}\n"               // 11: never
        ~ "    try g(); catch (Error) {}\n"                     // 12: never
        ~ "    // probing: absent means no\n"
        ~ "    try g(); catch (Exception) {}\n"                 // 14: comment above
        ~ "    auto s = \"catch (Exception) {}\";\n"            // 15: a string
        ~ "    try g(); catch (Exception e) {\n"                // 16: multi-line, swallows
        ~ "        retry();\n"
        ~ "    }\n"
        ~ "}\n"]]);
    assert(ids(r, "SD012") == ["SD012@3", "SD012@11", "SD012@12", "SD012@16"], ids(r, "SD012")[0]);
    // Test files are exempt.
    assert(ids(check([["a_test.d", ok ~ "unittest { try f(); catch (Exception) {} }\n"]]), "SD012") == []);
}

unittest // SD013
{
    auto r = check([["a.d", ok ~ "void f() { try g(); catch (Exception e) { log(e.msg); } }\n"],
        ["a_test.d", ok ~ "unittest { try g(); catch (Exception e) { log(e.msg); } }\n"]]);
    assert(countOf(r, "SD013") == 1);
}

unittest // SD014
{
    auto r = check([["a.d", ok
        ~ "void f(Role r, int n, string s) {\n"
        ~ "    switch (r) {\n"                    // 3: over an enum, has default
        ~ "        case Role.user: break;\n"
        ~ "        default: break;\n"
        ~ "    }\n"
        ~ "    final switch (r) {\n"              // fine
        ~ "        case Role.user: break;\n"
        ~ "        case Role.admin: break;\n"
        ~ "    }\n"
        ~ "    switch (s) {\n"                    // 11: strings may default
        ~ "        case \"a\": break;\n"
        ~ "        default: break;\n"
        ~ "    }\n"
        ~ "    switch (n) {\n"                    // 15: outer over ints, inner over an enum
        ~ "        case 1:\n"
        ~ "            switch (r) {\n"            // 17
        ~ "                case Role.user: break;\n"
        ~ "                default: break;\n"
        ~ "            }\n"
        ~ "            break;\n"
        ~ "        default: break;\n"
        ~ "    }\n"
        ~ "}\n"]]);
    assert(ids(r, "SD014") == ["SD014@3", "SD014@17"]);
    // On one line (the awk original missed this: it closed the switch first).
    auto one = check([["b.d", ok ~ "int f(M m) { switch (m) { case M.a: return 1; default: return 0; } }\n"]]);
    assert(ids(one, "SD014") == ["SD014@2"]);
}

unittest // SD015
{
    auto r = check([["a.d", ok
        ~ "class Agent {}\nclass BadInput : Exception { this() { super(\"\"); } }\n"
        ~ "struct S { Agent agent; }\n"
        ~ "void f(Agent a, S s, int* p) {\n"
        ~ "    if (a is null) return;\n"          // 7
        ~ "    if (s.agent !is null) {}\n"        // 8: member
        ~ "    if (!a) {}\n"                      // 9
        ~ "    if (p is null) {}\n"               // a pointer: not counted
        ~ "    // if (a is null)\n"
        ~ "}\n"]]);
    assert(countOf(r, "SD015") == 3);
    auto allowed = check(`{"allow":{"SD015":["a.d"]}}`, [["a.d", ok ~ "class C {}\nvoid f(C c) { if (c is null) {} }\n"]]);
    assert(countOf(allowed, "SD015") == 0);
}

unittest // SD016, SD017, SD019, SD020
{
    auto r = check([["a.d", ok
        ~ "Nullable!int a; Nullable!string b;\n"
        ~ "final class Agent {}\nstatic class Helper {}\nclass Oops : Exception {}\nclass ParseError : Exception {}\n"
        ~ "@nullable(\"set at startup\") Agent g;\n"
        ~ "auto x = cast(int) y; auto z = cast(const) w;\n"
        ~ "// cast(int) in a comment\n"]]);
    assert(countOf(r, "SD016") == 2);
    assert(countOf(r, "SD017") == 1);
    assert(countOf(r, "SD019") == 1);
    assert(countOf(r, "SD020") == 2);
    // The io modules may cast; test files don't count.
    auto io = check(`{"ioModules":["io.d"]}`, [["io.d", ok ~ "auto x = cast(int) y;\n"],
        ["t_test.d", ok ~ "auto x = cast(int) y;\n"]]);
    assert(countOf(io, "SD020") == 0);
}

unittest // SD018
{
    auto cfg = `{"nullAudit":{"module":"src/na_test.d","skip":["src/app.d"]}}`;
    auto r = check(cfg, [
        ["src/app.d", "module app;\n" ~ ok],
        ["src/a.d", "module p.a;\n" ~ ok],
        ["src/b.d", "module p.b;\n" ~ ok],
        ["src/na_test.d", "module p.na_test;\n" ~ ok ~ "static import p.a;\n// static import p.b;\n"]]);
    assert(ids(r, "SD018") == ["SD018@1"]);
    assert(r.findings[$ - 1].message == "add `static import p.b;` (and the modules list) to the null-audit module");
    auto missing = check(`{"nullAudit":{"module":"nope_test.d"}}`, [["a.d", ok]]);
    assert(ids(missing, "SD018") == ["SD018@1"]);
}

unittest // SD021
{
    enum good = `{"name":"p","toolchainRequirements":{"dmd":"no","gdc":"no","ldc":">=1.43.0"},
        "dflags":["-preview=dip1000","-preview=nosharedaccess"],"dflags-ldc":["-fno-delete-null-pointer-checks"],
        "buildTypes":{"release":{"dflags-ldc":["-boundscheck=on"]}},
        "preBuildCommands":["dub run -q --root \"$SAFE_D_PACKAGE_DIR\" :check -- --root \"$PACKAGE_DIR\""],
        "subPackages":[{"name":"none","targetType":"none"}]}`;
    assert(ids(check(`{}`, [["a.d", ok]], ["dub.json": good]), "SD021") == []);
    enum bad = `{"name":"p","toolchainRequirements":{"ldc":">=1.40.0"},"dflags":["-preview=dip1000"],
        "subPackages":[{"name":"lib","dflags":["-preview=dip1000","-preview=nosharedaccess"]}]}`;
    auto r = check(`{}`, [["a.d", ok]], ["dub.json": bad]);
    // root: nosharedaccess, null checks, dmd/gdc, ldc version, boundscheck, hook;
    // lib: null checks, dmd/gdc, ldc version, boundscheck (no hook for subpackages).
    assert(ids(r, "SD021").length == 10, ids(r, "SD021")[0]);
    auto noHook = check(`{"requireHook":false}`, [["a.d", ok]], ["dub.json": bad]);
    assert(ids(noHook, "SD021").length == 9);
    assert(ids(check(`{}`, [["a.d", ok]], ["dub.json": "{"]), "SD021") == ["SD021@1"]);
}

unittest // severities: off skips a rule, warn still reports
{
    string[2][] src = [["a.d", "module a;\n"]];
    assert(ids(check(`{"rules":{"SD001":"off"}}`, src), "SD001") == []);
    assert(ids(check(`{"rules":{"SD001":"warn"}}`, src), "SD001") == ["SD001@1"]);
    assert(countOf(check(`{"rules":{"SD020":"off"}}`, [["a.d", ok ~ "auto x = cast(int) y;\n"]]), "SD020") == -1);
}

unittest // escapes hidden in string mixins are still seen
{
    auto r = check([["a.d", ok
        ~ "// why\n"
        ~ "mixin(\"void f() @trusted {}\");\n"                    // 3: SD004, commented
        ~ "mixin(\"void g() @trusted {}\");\n"                    // 4: SD004 + SD006
        ~ "mixin(\"__gshared int x; auto y = cast(int) z;\");\n"  // 5: SD008, SD020
        ~ "enum msg = \"@trusted and cast(int) in a message\";\n"]]);
    assert(countOf(r, "SD004") == 2);
    assert(ids(r, "SD006") == ["SD006@4"]);
    assert(ids(r, "SD008") == ["SD008@5"]);
    assert(countOf(r, "SD020") == 1);
}

unittest // a CRLF checkout (Windows, core.autocrlf) gives the same findings as LF
{
    import std.array : replace;
    enum text = "module a;\n@safe:\nvoid f() @trusted {}\nint g(M m) { switch (m) { case M.a: return 1; default: return 0; } }\n"
        ~ "void h() {\n    try g(); catch (Exception) {}\n}\n";
    auto lf = check([["a.d", text]]);
    auto crlf = check([["a.d", text.replace("\n", "\r\n")]]);
    assert(ids(lf) == ids(crlf), ids(crlf)[0]);
    assert(ids(crlf, "SD001") == [] && ids(crlf, "SD006") == ["SD006@3"]);
}
