/// One test per rule: a snippet that must trip it and a near miss that
/// must not (often the same text in a comment or a string, which the old
/// grep-based scripts couldn't tell apart).
module safer.check.rules_test;

@safe:

import safer.check.config : Config, Severity, parseConfig;
import std.algorithm : canFind;
import safer.check.rules;

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
        "preBuildCommands":["dub run -q --root \"$SAFER_D_PACKAGE_DIR\" :check -- --root \"$PACKAGE_DIR\""],
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

private string[] whereOf(const Result r, string rule)
{
    foreach (c; r.counts)
        if (c.rule == rule) return c.where.dup;
    return null;
}

unittest // SD022
{
    auto r = check([["a.d", ok                                   // 1
        ~ "class C { int x; }\ninterface I {}\n"                     // 2-3
        ~ "struct S { C field; }\n"                                  // 4: a field: SD018's
        ~ "C global;\n"                                              // 5: a global: SD018's
        ~ "int f(C p, bool b) {\n"                                   // 6: a parameter
        ~ "    C a;\n"                                               // 7: count
        ~ "    C n = null;\n"                                        // 8: count
        ~ "    C made = new C;\n"                                    // 9
        ~ "    C fromCall = p;\n"                                    // 10
        ~ "    made = null;\n"                                       // 11: count
        ~ "    auto either = b ? made : null;\n"                     // 12: count
        ~ "    C picked = b ? null : p;\n"                           // 13: count
        ~ "    if (made == null) {}\n"                               // 14: a check: SD015's
        ~ "    int count;\n"                                         // 15: not a class
        ~ "    I i;\n"                                               // 16: count
        ~ "    static if (true) { C inner; }\n"                      // 17: count
        ~ "    // C commented;\n"                                    // 18
        ~ "    auto got = g(b ? made : null);\n"                      // 19: an argument
        ~ "    return made.x;\n"                                     // 20
        ~ "}\n"
        ~ "version (all) { C versioned; }\n"                         // 22: a global
        ~ "class D { C member; void g() { C local; } }\n"]]);        // 23: count the local only
    { import std.conv : to; assert(countOf(r, "SD022") == 8, whereOf(r, "SD022").to!string); }
    { import std.conv : to; auto w = whereOf(r, "SD022"); assert(w == ["a.d(7)", "a.d(8)", "a.d(11)", "a.d(12)", "a.d(13)", "a.d(16)", "a.d(17)", "a.d(23)"], w.to!string); }
    // Not counted: `auto` that isn't visibly a class, `is null` in a branch,
    // fields of a struct nested in a function, unittest blocks.
    auto quiet = check([["a.d", ok ~ "class C {}\nvoid f(int[string] o, bool b, C c) {\n"
        ~ "    auto p = b ? \"k\" in o : null;\n"
        ~ "    auto q = b ? c is null : false;\n"
        ~ "    static struct S { C field; }\n"
        ~ "    auto r = b ? new C : null;\n"                         // 7: count
        ~ "    auto s = b ? null : c;\n"                             // 8: count
        ~ "    auto u = b ? null : c.child;\n"                       // 9: type not visible
        ~ "}\nunittest { C t; }\n"]]);
    { import std.conv : to; auto w = whereOf(quiet, "SD022"); assert(w == ["a.d(7)", "a.d(8)"], w.to!string); }
    // Test files and allowed files don't count.
    auto t = check([["a_test.d", ok ~ "class C {}\nvoid f() { C c; }\n"]]);
    assert(countOf(t, "SD022") == 0);
    auto allowed = check(`{"allow":{"SD022":["a.d"]}}`, [["a.d", ok ~ "class C {}\nvoid f() { C c; }\n"]]);
    assert(countOf(allowed, "SD022") == 0);
}

unittest // SD015: a template argument isn't the declared type (`NotNull!C x;` is not a `C`)
{
    auto r = check([["a.d", ok
        ~ "class C {}\n"
        ~ "unittest { static assert(!__traits(compiles, { NotNull!C x; })); }\n"
        ~ "struct O(T) { this(T x) { if (x is null) assert(0); } }\n"]]);   // near miss
    assert(countOf(r, "SD015") == 0);
    auto hit = check([["a.d", ok ~ "class C {}\nvoid f(C x) { if (x is null) {} }\n"]]);
    assert(countOf(hit, "SD015") == 1);
}

unittest // SD023: pure-core modules throw only privately, and the throws are counted
{
    auto r = check([
        ["p.d", "module p;\n@safe:\npure:\n"
            ~ "class ParseError : Exception { this() { super(\"\"); } }\n"     // 4: public
            ~ "private class Unwind : Exception { this() { super(\"\"); } }\n"
            ~ "void f() { throw new Unwind(); }\n"                            // counted
            ~ "// throw in a comment\n"],
        ["q.d", "module q;\n@safe:\nclass E : Exception { this() { super(\"\"); } }\n"   // near miss: not pure-core
            ~ "void g() pure { throw new E(); }\n"]]);
    assert(ids(r, "SD023") == ["SD023@4"]);
    assert(countOf(r, "SD023") == 1);
    // Ships as a warning.
    assert(parseConfig(`{}`).severity("SD023") == Severity.warn);
}

unittest // SD024: module-level `version (unittest)` imports
{
    auto r = check([["a.d", ok
        ~ "version (unittest) import std.stdio;\n"                 // 2
        ~ "version (unittest)\n{\n    import std.file;\n"         // 5
        ~ "    void helper() { import std.path; }\n}\n"            // near miss: inside a function
        ~ "unittest { import std.conv; }\n"                        // near miss
        ~ "version (unittest) { static import std.array; }\n"]]);  // 9
    assert(ids(r, "SD024") == ["SD024@2", "SD024@5", "SD024@9"]);
    auto t = check([["t.d", "module t;\n@safe:\nversion (unittest):\nimport std.stdio;\n"
        ~ "version (unittest) import std.file;\n"]]);
    assert(ids(t, "SD024") == []);
}

unittest // project rules: ban, with except/only/testFiles, allow and rules
{
    enum rule = `{"id":"P001","kind":"ban","pattern":"\\bsetlocale\\b","message":"keep the C locale"`;
    string[2][] files = [
        ["src/a.d", ok ~ "void f() { setlocale(0, null); }\n// setlocale\nauto s = \"setlocale\";\n"],
        ["src/c.d", ok ~ "void g() { setlocale(0, null); }\n"],
        ["src/a_test.d", ok ~ "unittest { setlocale(0, null); }\n"],
        ["lib/b.d", ok ~ "void h() { setlocale(0, null); }\n"]];
    assert(ids(check(`{"projectRules":[` ~ rule ~ `}]}`, files), "P001") == ["P001@2", "P001@2", "P001@2"]);
    auto r = check(`{"projectRules":[` ~ rule ~ `,"except":["src/c.d"],"only":["src"],"testFiles":true}]}`, files);
    string[] where;
    foreach (f; r.findings) if (f.rule == "P001") where ~= f.file;
    assert(where == ["src/a.d", "src/a_test.d"]);
    auto allowed = check(`{"allow":{"P001":["src"]},"projectRules":[` ~ rule ~ `}]}`, files);
    assert(ids(allowed, "P001") == ["P001@2"]);
    auto off = check(`{"rules":{"P001":"off"},"projectRules":[` ~ rule ~ `}]}`, files);
    assert(ids(off, "P001") == []);
}

unittest // project rules: budget and floor count matches
{
    auto r = check(`{"projectRules":[
        {"id":"P001","kind":"budget","pattern":"\\bsleep\\b","budget":"sleep","message":"sleeps"},
        {"id":"P002","kind":"floor","pattern":"\\bpure\\b(?!:)","floor":5,"message":"pure attributes"}]}`, [
        ["a.d", ok ~ "pure:\nint f() pure { sleep(); sleep(); return 0; }\nint g() pure;\n// pure sleep\n"],
        ["a_test.d", ok ~ "int h() pure { sleep(); return 0; }\n"]]);
    assert(countOf(r, "P001") == 2);
    foreach (c; r.counts) if (c.rule == "P001") assert(c.budget == "sleep");
    assert(r.floors.length == 1 && r.floors[0].count == 2 && r.floors[0].floor == 5);
}

unittest // project rules: listed (and exact)
{
    enum cfg = `{"projectRules":[{"id":"P001","kind":"listed","select":"^pure:","listIn":"src/pc_test.d",
        "except":["src/audit.d"],"exact":true,"message":"list pure-core modules"}]}`;
    auto r = check(cfg, [
        ["src/a.d", "module app.a;\n@safe:\npure:\n"],
        ["src/b.d", "module app.b;\n@safe:\npure:\n"],                    // not listed
        ["src/audit.d", "module app.audit;\n@safe:\npure:\n"],            // excepted
        ["src/c.d", "module app.c;\n@safe:\nint f() pure;\n"],            // not pure-core
        ["src/pc_test.d", "module app.pc_test;\n@safe:\nimport app.audit : x;\nstatic import app.a;\n"
            ~ "static import app.c;\n// static import app.b;\n"]]);
    assert(ids(r, "P001") == ["P001@1", "P001@5"]);
    assert(r.findings[0].message.canFind("app.b") && r.findings[1].message.canFind("app.c"));
    auto missing = check(`{"projectRules":[{"id":"P001","kind":"listed","select":"x","listIn":"nope.d","message":"m"}]}`,
        [["a.d", ok]]);
    assert(ids(missing, "P001") == ["P001@1"]);
}
