/// The Safe D rules. Each has an id (`SD001`...), and those that cap a count
/// rather than ban a pattern have a budget name, whose value lives in the
/// project's `safe-d.json`. SAFE-D.md gives the reasoning for each.
module safed.check.rules;

@safe:

import std.regex : matchAll, matchFirst, regex, Regex;

/// `pattern`, compiled once per thread on first use. Not ctRegex: building
/// these at compile time crashes LDC 1.43 on Windows (0xC000001D), and the
/// run-time compile happens once per pattern either way.
Regex!char re(string pattern)()
{
    static Regex!char compiled;
    static bool ready;
    if (!ready)
    {
        compiled = regex(pattern);
        ready = true;
    }
    return compiled;
}
import std.algorithm : canFind, endsWith, startsWith;
import std.string : strip, stripRight;
import safed.check.config : Config, Severity;
import safed.check.lexer : Line, lex, isBlank;

/// A rule, for `--rules` and the docs.
struct Rule
{
    string id;
    /// The budget it ratchets, or null for a ban.
    string budget;
    string title;
}

/// Every rule, in id order.
static immutable Rule[] allRules = [
    Rule("SD001", null, "every module has a module-level `@safe:`"),
    Rule("SD002", null, "no `@system:` or `@trusted:` labels"),
    Rule("SD003", null, "`@system` only on `extern (C)` declarations"),
    Rule("SD004", "trusted", "`@trusted` outside the io modules is capped"),
    Rule("SD005", "trusted-io", "`@trusted` inside the io modules is capped"),
    Rule("SD006", null, "a comment above every `@trusted` and `assumeIsolated` says why it is safe"),
    Rule("SD007", null, "no raw threads (`new Thread`, `isDaemon`, `std.concurrency`) outside the io modules; use safed.concurrency.spawn"),
    Rule("SD008", null, "no `__gshared` or `union` outside the io modules"),
    Rule("SD009", "isolation", "`assumeIsolated` calls outside the io modules are capped"),
    Rule("SD010", null, "no hand-written `a > b ? a - b : 0`; use safed.arith.saturatingSub"),
    Rule("SD011", "subtraction", "raw subtractions in the `subtractionScope` modules are capped"),
    Rule("SD012", null, "a `catch (Exception)` that swallows says why; never catch `Throwable` or `Error`"),
    Rule("SD013", "catch", "`catch (Exception)` outside test files is capped"),
    Rule("SD014", null, "a `switch` over an enum is a `final switch` (no `default:`)"),
    Rule("SD015", "class-null", "null checks on class references are capped; use safed.option.Option"),
    Rule("SD016", "nullable", "`Nullable!` uses are capped; use safed.option.Option"),
    Rule("SD017", "class", "class declarations (exceptions aside) are capped; prefer a struct, enum or SumType"),
    Rule("SD018", null, "the null-audit module imports every module"),
    Rule("SD019", "nullable-mark", "`@nullable(\"why\")` marks are capped"),
    Rule("SD020", "cast", "`cast(` outside the io modules is capped"),
    Rule("SD021", null, "dub.json keeps the Safe D compiler settings"),
    Rule("SD022", "null-local", "class-typed locals that start or become null are capped; initialise them, or use safed.option.Option"),
];

/// The rule with `id`.
Rule ruleById(string id) pure
{
    foreach (r; allRules)
        if (r.id == id) return r;
    assert(0, "no rule " ~ id);
}

/// One source file, lexed.
struct Source
{
    /// Path relative to the project root, `/`-separated.
    string path;
    Line[] lines;
}

/// Lex `text` as the file at `path`.
/// Lex `text` as the file at `path`. CRLF line endings (a Windows checkout
/// with `core.autocrlf`) read the same as LF.
Source source(string path, string text) pure
{
    import std.array : replace;
    return Source(path, lex(text.replace("\r\n", "\n")));
}

/// One violation.
struct Finding
{
    string rule;
    string file;
    size_t line;
    string message;
}

/// A counted rule's result: how many, where, against which budget.
struct Count
{
    string rule;
    string budget;
    string what;
    long count;
    /// "file(line)" for each counted occurrence.
    string[] where;
}

/// Everything a run found.
struct Result
{
    Finding[] findings;
    Count[] counts;
}

/// Run every rule that is not `off` over `files` (and the dub.json texts,
/// given as path => text).
Result runRules(const ref Config cfg, const Source[] files, const string[string] dubJsons)
{
    Result r;
    bool on(string id) { return cfg.severity(id) != Severity.off; }

    if (on("SD001")) sd001(cfg, files, r);
    if (on("SD002") || on("SD003")) sd002_003(cfg, files, r);
    trustedCounts(cfg, files, r);
    if (on("SD006")) sd006(cfg, files, r);
    if (on("SD007") || on("SD008")) sd007_008(cfg, files, r);
    countLines(cfg, files, r, "SD009", "`assumeIsolated` calls outside the io modules",
        (f) => !cfg.isIo(f.path), (code) => countMatches(code, re!`\bassumeIsolated\(`), true);
    if (on("SD010")) sd010(cfg, files, r);
    sd011(cfg, files, r);
    if (on("SD012")) sd012(cfg, files, r);
    countLines(cfg, files, r, "SD013", "`catch (Exception)` outside test files",
        (f) => !cfg.isTest(f.path), (code) => matchFirst(code, re!`catch\s*\(\s*Exception\b`) ? 1 : 0);
    if (on("SD014")) sd014(cfg, files, r);
    sd015(cfg, files, r);
    countLines(cfg, files, r, "SD016", "`Nullable!` uses outside test files (use safed.option.Option)",
        (f) => !cfg.isTest(f.path), (code) => countMatches(code, re!`Nullable!`));
    countLines(cfg, files, r, "SD017", "class declarations outside test files (exceptions aside)",
        (f) => !cfg.isTest(f.path), (code) => isClassDecl(code) ? 1 : 0);
    if (on("SD018")) sd018(cfg, files, r);
    countLines(cfg, files, r, "SD019", "`@nullable` marks outside test files",
        (f) => !cfg.isTest(f.path), (code) => matchFirst(code, re!`^\s*@nullable\(`) ? 1 : 0);
    countLines(cfg, files, r, "SD020", "`cast(` outside the io modules and test files",
        (f) => !cfg.isTest(f.path) && !cfg.isIo(f.path), (code) => countMatches(code, re!`(^|[^\w])cast\s*\(`), true);
    if (on("SD021")) sd021(cfg, dubJsons, r);
    sd022(cfg, files, r);
    return r;
}

private size_t countMatches(R)(string s, R re)
{
    size_t n;
    foreach (_; matchAll(s, re)) n++;
    return n;
}

private string at(string file, size_t line)
{
    import std.conv : to;
    return file ~ "(" ~ line.to!string ~ ")";
}

/// A counted rule: `select` picks the files, `perLine` counts on one line's code.
private void countLines(const ref Config cfg, const Source[] files, ref Result r, string id, string what,
    scope bool delegate(const ref Source) @safe select, scope size_t delegate(string) @safe perLine,
    bool escapes = false)
{
    if (cfg.severity(id) == Severity.off) return;
    auto rule = ruleById(id);
    Count c = Count(id, rule.budget, what);
    foreach (ref f; files)
    {
        if (!select(f) || cfg.allowed(id, f.path)) continue;
        foreach (ref l; f.lines)
        {
            immutable n = perLine(escapes ? l.escapeText : l.code);
            if (n)
            {
                c.count += n;
                c.where ~= at(f.path, l.number);
            }
        }
    }
    r.counts ~= c;
}

// ---- SD001-SD005: @safe everywhere, escapes counted -----------------------

private void sd001(const ref Config cfg, const Source[] files, ref Result r)
{
    foreach (ref f; files)
    {
        if (cfg.allowed("SD001", f.path)) continue;
        bool found;
        foreach (ref l; f.lines)
            if (l.code.startsWith("@safe:")) { found = true; break; }
        if (!found)
            r.findings ~= Finding("SD001", f.path, 1, "module is missing a module-level `@safe:`");
    }
}

private void sd002_003(const ref Config cfg, const Source[] files, ref Result r)
{
    auto label = re!`^\s*@(system|trusted)\s*:`;
    auto system = re!`(^|[^\w])@system\b`;
    foreach (ref f; files)
        foreach (ref l; f.lines)
        {
            immutable text = l.escapeText;
            if (cfg.severity("SD002") != Severity.off && !cfg.allowed("SD002", f.path) && matchFirst(text, label))
                r.findings ~= Finding("SD002", f.path, l.number,
                    "`@system:`/`@trusted:` turn off @safe for the rest of a scope; mark the smallest function or lambda instead");
            else if (cfg.severity("SD003") != Severity.off && !cfg.allowed("SD003", f.path)
                && matchFirst(text, system) && !matchFirst(text, re!`extern\s*\(\s*C\s*\)`))
                r.findings ~= Finding("SD003", f.path, l.number,
                    "`@system` is only allowed on `extern (C)` declarations; use @safe, or @trusted on the smallest function or lambda");
        }
}

private bool hasTrusted(string code)
{
    return !matchFirst(code, re!`(^|[^\w])@trusted\b`).empty;
}

private void trustedCounts(const ref Config cfg, const Source[] files, ref Result r)
{
    countLines(cfg, files, r, "SD004", "`@trusted` outside the io modules",
        (f) => !cfg.isIo(f.path), (code) => hasTrusted(code) ? 1 : 0, true);
    countLines(cfg, files, r, "SD005", "`@trusted` in the io modules",
        (f) => cfg.isIo(f.path), (code) => hasTrusted(code) ? 1 : 0, true);
}

// ---- SD006: every escape says why -----------------------------------------

private bool endsStatement(string code)
{
    auto s = code.stripRight;
    return s.length && (s[$ - 1] == ';' || s[$ - 1] == '{' || s[$ - 1] == '}');
}

private void sd006(const ref Config cfg, const Source[] files, ref Result r)
{
    foreach (ref f; files)
    {
        if (cfg.allowed("SD006", f.path)) continue;
        immutable io = cfg.isIo(f.path);
        bool ok;
        foreach (ref l; f.lines)
        {
            if (l.blank) continue;
            if (l.commentOnly) { ok = true; continue; }
            immutable trusted = hasTrusted(l.escapeText);
            if (trusted || l.escapeText.canFind(".assumeIsolated("))
            {
                // In the io modules every function is an escape, so an
                // `assumeIsolated` there needs no separate note; a
                // `@trusted` always does.
                if (!ok && (trusted || !io))
                    r.findings ~= Finding("SD006", f.path, l.number,
                        "`@trusted` or `assumeIsolated` without a comment above it saying why it is safe");
                if (endsStatement(l.code)) ok = false;
                continue;
            }
            if (endsStatement(l.code)) ok = false;
        }
    }
}

// ---- SD007-SD008: threads only through spawn, no unchecked sharing ---------

private void sd007_008(const ref Config cfg, const Source[] files, ref Result r)
{
    auto threads = re!`\bnew Thread\b|\bisDaemon\b|\bstd\.concurrency\b`;
    auto global = re!`\b__gshared\b|(^|[^\w])union\b`;
    foreach (ref f; files)
    {
        if (cfg.isIo(f.path)) continue;
        foreach (ref l; f.lines)
        {
            immutable text = l.escapeText;
            if (cfg.severity("SD007") != Severity.off && !cfg.allowed("SD007", f.path) && matchFirst(text, threads))
                r.findings ~= Finding("SD007", f.path, l.number,
                    "start threads with safed.concurrency.spawn/spawnDaemon (sendable arguments only)");
            if (cfg.severity("SD008") != Severity.off && !cfg.allowed("SD008", f.path) && matchFirst(text, global))
                r.findings ~= Finding("SD008", f.path, l.number,
                    "`__gshared` and unions are only allowed in the io modules; use `shared` with Locked/atomics, or std.sumtype");
        }
    }
}

// ---- SD010-SD011: size arithmetic -----------------------------------------

private void sd010(const ref Config cfg, const Source[] files, ref Result r)
{
    // std.regex has no backreferences in ctRegex patterns over captures used
    // this way, so compare the captured operands by hand.
    auto guard = regex(`([\w.]+) >=? ([\w.]+) \? ([\w.]+) - ([\w.]+) : 0`);
    foreach (ref f; files)
    {
        if (cfg.allowed("SD010", f.path)) continue;
        foreach (ref l; f.lines)
            foreach (m; matchAll(l.code, guard))
                if (m[1] == m[3] && m[2] == m[4])
                    r.findings ~= Finding("SD010", f.path, l.number,
                        "use safed.arith.saturatingSub(a, b) instead of `a > b ? a - b : 0`");
    }
}

/// Raw binary subtractions on one line of code (`$ - 1` index steps aside).
size_t rawSubtractions(string code)
{
    import std.regex : replaceAll;
    auto s = replaceAll(code, re!`\$\s*-`, "");
    return countMatches(s, re!`[\w)\]]\s+-\s+[\w(]`);
}

private void sd011(const ref Config cfg, const Source[] files, ref Result r)
{
    if (cfg.severity("SD011") == Severity.off) return;
    Count c = Count("SD011", "subtraction", "raw subtractions in the subtractionScope modules");
    foreach (ref f; files)
    {
        import safed.check.config : underAny;
        if (!underAny(f.path, cfg.subtractionScope) || cfg.allowed("SD011", f.path)) continue;
        foreach (ref l; f.lines)
            if (immutable n = rawSubtractions(l.code))
            {
                c.count += n;
                c.where ~= at(f.path, l.number);
            }
    }
    r.counts ~= c;
}

// ---- SD012: catches -------------------------------------------------------

private void sd012(const ref Config cfg, const Source[] files, ref Result r)
{
    auto never = re!`catch\s*\(\s*(Throwable|Error)(\s|\))`;
    auto head = re!`catch\s*\(\s*Exception(\s+(\w+))?\s*\)`;
    auto throws = re!`(^|[^\w])throw([^\w]|$)`;
    foreach (ref f; files)
    {
        if (cfg.isTest(f.path) || cfg.allowed("SD012", f.path)) continue;
        bool inHandler, prevComment, commented, uses, opened;
        long depth;
        size_t catchLine;
        string var;

        bool usesVar(string code)
        {
            if (!var.length) return false;
            return !matchFirst(code, regex(`(^|[^\w.])` ~ var ~ `([^\w]|$)`)).empty;
        }
        bool scan(string code)
        {
            foreach (ch; code)
            {
                if (ch == '{') { depth++; opened = true; }
                else if (ch == '}') depth--;
            }
            return (opened && depth <= 0) || (!opened && code.stripRight.endsWith(";"));
        }
        void report()
        {
            if (uses || commented) return;
            r.findings ~= Finding("SD012", f.path, catchLine,
                "`catch (Exception)` swallows the exception; say why in a `//` comment (or report or rethrow it)");
        }

        foreach (ref l; f.lines)
        {
            immutable isComment = l.commentOnly;
            if (inHandler)
            {
                if (l.hasComment) commented = true;
                if (matchFirst(l.code, throws) || usesVar(l.code)) uses = true;
                if (scan(l.code)) { report(); inHandler = false; }
                if (isComment) prevComment = true;
                else if (!isBlank(l.code)) prevComment = false;
                continue;
            }
            if (matchFirst(l.code, never))
            {
                r.findings ~= Finding("SD012", f.path, l.number,
                    "don't catch `Throwable` or `Error`: they mean a broken invariant or out of memory, and @safe code can't recover from them");
                continue;
            }
            if (auto m = matchFirst(l.code, head))
            {
                var = m[2];
                auto rest = m.post;
                catchLine = l.number;
                commented = prevComment || l.hasComment;
                uses = false;
                depth = 0;
                opened = false;
                if (matchFirst(rest, throws) || usesVar(rest)) uses = true;
                if (scan(rest)) report();
                else inHandler = true;
                prevComment = false;
                continue;
            }
            if (isComment) prevComment = true;
            else if (!isBlank(l.code)) prevComment = false;
        }
    }
}

// ---- SD014: exhaustive enum switches --------------------------------------

private void sd014(const ref Config cfg, const Source[] files, ref Result r)
{
    auto sw = re!`(^|[^\w])switch\s*\(`;
    auto fin = re!`final\s+switch`;
    auto enumCase = re!`(^|[^\w])case\s+[A-Z]\w*\.\w+`;
    auto dflt = re!`(^|[^\w])default\s*:`;
    struct Open { long depth; size_t line; bool overEnum, hasDefault; }
    foreach (ref f; files)
    {
        if (cfg.allowed("SD014", f.path)) continue;
        Open[] stack;
        long depth;
        bool pending;
        size_t pendingLine;
        // Labels in `seg` belong to the innermost open switch when they sit
        // directly in its body (or open a `case X: { ... }` block).
        void labels(string seg)
        {
            if (!stack.length || !(depth == stack[$ - 1].depth || depth == stack[$ - 1].depth + 1)) return;
            if (matchFirst(seg, enumCase)) stack[$ - 1].overEnum = true;
            if (matchFirst(seg, dflt)) stack[$ - 1].hasDefault = true;
        }
        foreach (ref l; f.lines)
        {
            auto s = l.code;
            if (matchFirst(s, sw) && !matchFirst(s, fin)) { pending = true; pendingLine = l.number; }
            size_t from;
            foreach (i, ch; s)
            {
                if (ch != '{' && ch != '}') continue;
                labels(s[from .. i]);
                from = i + 1;
                if (ch == '{')
                {
                    depth++;
                    if (pending) { stack ~= Open(depth, pendingLine); pending = false; }
                }
                else
                {
                    if (stack.length && stack[$ - 1].depth == depth)
                    {
                        auto o = stack[$ - 1];
                        if (o.overEnum && o.hasDefault)
                            r.findings ~= Finding("SD014", f.path, o.line,
                                "`switch` over an enum has a `default:`; use `final switch` and list the skipped members");
                        stack = stack[0 .. $ - 1];
                    }
                    depth--;
                }
            }
            labels(s[from .. $]);
        }
    }
}

// ---- SD015: null checks on class references --------------------------------

/// Names of the project's classes and interfaces (exceptions aside).
private bool[string] classNames(const Source[] files)
{
    bool[string] classes;
    auto decl = re!`(^|[^\w])(class|interface)[ \t]+([A-Z]\w*)`;
    foreach (ref f; files)
        foreach (ref l; f.lines)
            if (auto m = matchFirst(l.code, decl))
                if (!m[3].endsWith("Error") && !m[3].endsWith("Exception")) classes[m[3]] = true;
    return classes;
}

private void sd015(const ref Config cfg, const Source[] files, ref Result r)
{
    if (cfg.severity("SD015") == Severity.off) return;
    auto classes = classNames(files);

    bool[string] local;     // file ~ "\0" ~ name
    bool[string] member;
    auto typed = re!`[^\w.]([A-Z]\w*)\)?[ \t]+([a-z_]\w*)[ \t]*[;=,)]`;
    foreach (ref f; files)
        foreach (ref l; f.lines)
            foreach (m; matchAll(" " ~ l.code, typed))
                if (m[1] in classes)
                {
                    local[f.path ~ "\0" ~ m[2]] = true;
                    member[m[2]] = true;
                }

    bool counts(string file, string reference)
    {
        import std.string : lastIndexOf;
        immutable dot = reference.lastIndexOf('.');
        if (dot >= 0) return (reference[dot + 1 .. $] in member) !is null;
        return (file ~ "\0" ~ reference in local) !is null;
    }

    Count c = Count("SD015", "class-null", "null checks on class references (use safed.option.Option)");
    auto isNull = re!`([A-Za-z_][\w.]*)[ \t]*!?is[ \t]+null`;
    auto ifRef = re!`if[ \t]*\([ \t]*(!|auto[ \t]+[A-Za-z_]\w*[ \t]*=)?[ \t]*([A-Za-z_][\w.]*)[ \t]*\)`;
    foreach (ref f; files)
    {
        if (cfg.isTest(f.path) || cfg.allowed("SD015", f.path)) continue;
        foreach (ref l; f.lines)
        {
            bool hit;
            foreach (m; matchAll(l.code, isNull))
                if (counts(f.path, m[1])) hit = true;
            foreach (m; matchAll(l.code, ifRef))
                if (counts(f.path, m[2])) hit = true;
            if (hit)
            {
                c.count++;
                c.where ~= at(f.path, l.number);
            }
        }
    }
    r.counts ~= c;
}

// ---- SD017: class declarations ----------------------------------------------

/// A class declaration that counts against the budget: not an exception,
/// and not a `static class` (helpers inside unittests).
bool isClassDecl(string code)
{
    if (!matchFirst(code, re!`^\s*((final|abstract|private|public)\s+)*class\s+[A-Z]`)) return false;
    return !matchFirst(code, re!`class\s+\w*(Error|Exception)\b|:\s*Exception`);
}

// ---- SD018: the null audit lists every module --------------------------------

private void sd018(const ref Config cfg, const Source[] files, ref Result r)
{
    foreach (na; cfg.nullAudit)
    {
        import safed.check.config : underAny;
        const(Source)* audit;
        foreach (ref f; files)
            if (f.path == na.module_) audit = &f;
        if (audit is null)
        {
            r.findings ~= Finding("SD018", na.module_, 1, "the null-audit module named in safe-d.json doesn't exist");
            return;
        }
        bool[string] imported;
        auto si = re!`^\s*static\s+import\s+([\w.]+)\s*;`;
        foreach (ref l; audit.lines)
            if (auto m = matchFirst(l.code, si)) imported[m[1]] = true;
        auto mod = re!`^\s*module\s+([\w.]+)\s*;`;
        foreach (ref f; files)
        {
            if (cfg.isTest(f.path) || underAny(f.path, na.skip) || cfg.allowed("SD018", f.path)) continue;
            foreach (ref l; f.lines)
                if (auto m = matchFirst(l.code, mod))
                {
                    if (m[1] !in imported)
                        r.findings ~= Finding("SD018", na.module_, 1,
                            "add `static import " ~ m[1] ~ ";` (and the modules list) to the null-audit module");
                    break;
                }
        }
    }
}

// ---- SD021: dub.json keeps the compiler settings ------------------------------

private void sd021(const ref Config cfg, const string[string] dubJsons, ref Result r)
{
    import std.json : JSONValue, JSONType, parseJSON, JSONException;
    import std.algorithm : sort;
    import std.array : array;
    import safed.json : jsonGet;

    string[] flagsOf(const ref JSONValue pkg, string key)
    {
        string[] out_;
        if (auto v = jsonGet(pkg, key))
            if (v.type == JSONType.array)
                foreach (e; v.arrayNoRef)
                    if (e.type == JSONType.string) out_ ~= e.str;
        return out_;
    }

    void checkPackage(string file, const ref JSONValue pkg, string name, bool root)
    {
        void bad(string msg) { r.findings ~= Finding("SD021", file, 1, name ~ ": " ~ msg); }
        if (auto t = jsonGet(pkg, "targetType"))
            if (t.type == JSONType.string && t.str == "none") return;

        auto flags = flagsOf(pkg, "dflags") ~ flagsOf(pkg, "dflags-ldc");
        foreach (want; ["-preview=dip1000", "-preview=nosharedaccess"])
            if (!flags.canFind(want)) bad("`dflags` must include `" ~ want ~ "`");
        if (!flagsOf(pkg, "dflags-ldc").canFind("-fno-delete-null-pointer-checks"))
            bad("`dflags-ldc` must include `-fno-delete-null-pointer-checks`");

        auto tc = jsonGet(pkg, "toolchainRequirements");
        string req(string compiler)
        {
            if (tc is null) return null;
            if (auto v = jsonGet(*tc, compiler)) if (v.type == JSONType.string) return v.str;
            return null;
        }
        if (req("dmd") != "no" || req("gdc") != "no")
            bad("`toolchainRequirements` must set `\"dmd\": \"no\"` and `\"gdc\": \"no\"` (LDC only)");
        if (!ldcAtLeast(req("ldc"), 1, 43))
            bad("`toolchainRequirements.ldc` must require `>=1.43.0` or newer");

        bool boundsOn;
        if (auto bt = jsonGet(pkg, "buildTypes"))
            if (auto rel = jsonGet(*bt, "release"))
                boundsOn = (flagsOf(*rel, "dflags") ~ flagsOf(*rel, "dflags-ldc")).canFind("-boundscheck=on");
        if (!boundsOn) bad("`buildTypes.release` must keep `-boundscheck=on` in its `dflags-ldc`");

        if (root && cfg.requireHook)
        {
            bool hooked;
            foreach (c; flagsOf(pkg, "preBuildCommands"))
                if (c.canFind("SAFE_D_PACKAGE_DIR") || c.canFind("safe-d") || c.canFind("check-safe")) hooked = true;
            if (!hooked) bad("`preBuildCommands` must run safe-d-check, so every build is checked");
        }
    }

    foreach (file; dubJsons.keys.array.sort)
    {
        JSONValue root;
        try root = parseJSON(dubJsons[file]);
        catch (JSONException e)
        {
            r.findings ~= Finding("SD021", file, 1, "not valid JSON: " ~ e.msg);
            continue;
        }
        string pname = "package";
        if (auto n = jsonGet(root, "name")) if (n.type == JSONType.string) pname = n.str;
        checkPackage(file, root, pname, true);
        if (auto subs = jsonGet(root, "subPackages"))
            if (subs.type == JSONType.array)
                foreach (s; subs.arrayNoRef)
                    if (s.type == JSONType.object)
                    {
                        string sname = pname ~ ":?";
                        if (auto n = jsonGet(s, "name")) if (n.type == JSONType.string) sname = pname ~ ":" ~ n.str;
                        checkPackage(file, s, sname, false);
                    }
    }
}

/// Whether a dub version requirement such as `>=1.43.0` admits only LDC
/// `major.minor` or newer.
bool ldcAtLeast(string req, int major, int minor)
{
    import std.conv : to, ConvException;
    if (!req.startsWith(">=")) return false;
    auto m = matchFirst(req[2 .. $].strip, re!`^(\d+)\.(\d+)`);
    if (!m) return false;
    try
    {
        immutable a = m[1].to!int, b = m[2].to!int;
        return a > major || (a == major && b >= minor);
    }
    catch (ConvException e)
        return false;   // digits that don't fit an int: not a version we can trust
}

unittest
{
    assert(ldcAtLeast(">=1.43.0", 1, 43) && ldcAtLeast(">=1.44.1", 1, 43) && ldcAtLeast(">=2.0.0", 1, 43));
    assert(!ldcAtLeast(">=1.42.0", 1, 43) && !ldcAtLeast("~>1.43.0", 1, 43) && !ldcAtLeast(null, 1, 43));
    assert(rawSubtractions("a - b; x[$ - 1]; f(c) - (d)") == 2);
    assert(isClassDecl("final class Agent") && !isClassDecl("class FooException : Exception")
        && !isClassDecl("static class Helper") && !isClassDecl("int class_;"));
}

// ---- SD022: class-typed locals that start or become null ---------------------

/// Which kind of scope each `{` on the way to a line opened.
private enum Scope : ubyte { module_, aggregate, function_, test }

/// Whether a block header opens an aggregate (its `{` holds fields).
private bool opensAggregate(string header)
{
    return !matchFirst(header,
        re!`(^|[\s;}])((final|abstract|private|public|package|protected|static|extern\s*\([^)]*\)|@\w+)\s+)*(struct|class|interface|union|template|enum)\b`).empty;
}

/// Whether a block header only groups declarations (`static if`, `version`,
/// attribute blocks): the block is the same kind of scope as its parent.
private bool groupsDeclarations(string header)
{
    return !matchFirst(header,
        re!`^\s*(static\s+if|static\s+foreach|version|debug|else|extern|private|public|package|protected|shared|static|@\w+)\b|^\s*$`).empty;
}

/// The scope of every character of each line's code in `f`. Braces in
/// strings and comments are already gone from `Line.code`.
private Scope[][] charScopes(const ref Source f)
{
    Scope[] stack = [Scope.module_];
    Scope[][] at;
    at.length = f.lines.length;
    string header;
    foreach (i, ref l; f.lines)
    {
        at[i].length = l.code.length;
        foreach (j, ch; l.code)
        {
            at[i][j] = stack[$ - 1];
            if (ch == '{')
            {
                const parent = stack[$ - 1];
                Scope next;
                if (parent == Scope.test || !matchFirst(header, re!`^\s*unittest\b`).empty) next = Scope.test;
                else if (opensAggregate(header)) next = Scope.aggregate;
                else if (parent == Scope.function_) next = Scope.function_;
                else if (groupsDeclarations(header)) next = parent;
                else next = Scope.function_;
                stack ~= next;
                header = null;
            }
            else if (ch == '}')
            {
                if (stack.length > 1) stack = stack[0 .. $ - 1];
                header = null;
            }
            else if (ch == ';') header = null;
            else header ~= ch;
        }
        header ~= ' ';
    }
    return at;
}

/// SD022: inside function bodies, count the ways a class-typed local becomes
/// null: declared without an initialiser (`C c;`), initialised or assigned
/// `null` (`C c = null;`, `c = null;`, `auto c = b ? x : null;`). A local
/// that is always initialised from `new` or a call can't start null, and
/// absence that is real belongs in `Option!C`. Fields and globals are the
/// null audit's (SD018/SD019); null checks are SD015's.
private void sd022(const ref Config cfg, const Source[] files, ref Result r)
{
    if (cfg.severity("SD022") == Severity.off) return;
    auto classes = classNames(files);
    Count c = Count("SD022", "null-local", "class-typed locals that start or become null (initialise them, or use safed.option.Option)");
    auto noInit = re!`(^|[^\w.!])([A-Z]\w*)[ \t]+([a-z_]\w*)[ \t]*;`;
    auto typedInit = re!`(^|[^\w.!])([A-Z]\w*)[ \t]+([a-z_]\w*)[ \t]*=[ \t]*([^=;][^;]*)`;
    auto autoInit = re!`(^|[^\w.])(auto|const|immutable)[ \t]+([a-z_]\w*)[ \t]*=[ \t]*([^=;][^;]*)`;
    auto assign = re!`(^|[^\w.])([a-z_]\w*)[ \t]*=[ \t]*([^=;][^;]*)`;
    // `null` as the value, or as a branch of `?:`.
    // The top level of `rhs`: not inside a call's arguments, an index or a
    // lambda.
    string topLevel(string rhs)
    {
        string top;
        int depth;
        foreach (ch; rhs)
        {
            if (ch == '(' || ch == '[' || ch == '{') depth++;
            else if (ch == ')' || ch == ']' || ch == '}') { if (depth) depth--; }
            else if (!depth) top ~= ch;
        }
        return top;
    }
    // `null` as the whole value, or as a whole branch of a top-level `?:`.
    bool nullValue(string rhs)
    {
        return !matchFirst(topLevel(rhs), re!`^\s*null\s*$|\?\s*null\s*:|:\s*null\s*$`).empty;
    }
    foreach (ref f; files)
    {
        if (cfg.isTest(f.path) || cfg.allowed("SD022", f.path)) continue;
        auto scopes = charScopes(f);
        bool[string] locals; // class-typed locals seen in this file
        foreach (i, ref l; f.lines)
        {
            // Whether the match `m` sits in a function body (group 1 is the
            // boundary before it, in the same scope).
            bool inBody(M)(M m)
            {
                const off = m.pre.length + m[1].length;
                return off < scopes[i].length && scopes[i][off] == Scope.function_;
            }
            size_t n;
            // Class-typed parameters: known class references, not counted.
            foreach (m; matchAll(l.code, re!`(^|[^\w.!])([A-Z]\w*)[ \t]+([a-z_]\w*)[ \t]*[,)]`))
                if (m[2] in classes) locals[m[3]] = true;
            foreach (m; matchAll(l.code, noInit))
                if (m[2] in classes && inBody(m)) { locals[m[3]] = true; n++; }
            foreach (m; matchAll(l.code, typedInit))
                if (m[2] in classes && inBody(m))
                {
                    locals[m[3]] = true;
                    if (nullValue(m[4])) n++;
                }
            // `auto x = b ? y : null`: the type isn't written, so count it only
            // when the other branch is visibly a class (`new C`, `C.make()`,
            // or a class-typed local).
            foreach (m; matchAll(l.code, autoInit))
                if (nullValue(m[4]) && inBody(m))
                    if (auto br = matchFirst(topLevel(m[4]), re!`\?\s*(.*?)\s*:\s*(.*?)\s*$`))
                    {
                        const other = br[1] == "null" ? br[2] : br[1];
                        if (auto id = matchFirst(other, re!`^(new\s+)?([A-Za-z_]\w*)$`))
                            if (id[2] in classes || id[2] in locals) { locals[m[3]] = true; n++; }
                    }
            if (!n)
                foreach (m; matchAll(l.code, assign))
                    if (m[2] in locals && nullValue(m[3]) && inBody(m)) n++;
            if (n)
            {
                c.count += n;
                c.where ~= at(f.path, l.number);
            }
        }
    }
    r.counts ~= c;
}
