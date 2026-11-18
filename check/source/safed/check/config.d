/// `safe-d.json`: where a project's code is, which modules hold its
/// reviewed escapes, and its budgets. Every key is optional; a budget that
/// is missing is 0, so a new project starts at the strictest setting.
///
/// ---
/// {
///   "sources": ["source"],
///   "exclude": ["source/vendor"],
///   "ioModules": ["source/app/safeio.d"],
///   "testFiles": ["*_test.d"],
///   "subtractionScope": ["source/app/budget.d"],
///   "nullAudit": { "module": "source/app/null_audit_test.d", "skip": ["source/app.d"] },
///   "allow": { "SD010": ["source/app/arith.d"] },
///   "rules": { "SD020": "warn" },
///   "budgets": { "trusted": 0, "catch": 3 },
///   "dubFiles": ["dub.json"],
///   "requireHook": true
/// }
/// ---
module safed.check.config;

@safe:

import std.json : JSONOptions, JSONValue, JSONType, parseJSON;
import safed.json : jsonGet;
import safed.option : Option, some, none;

/// What a rule's findings do.
enum Severity
{
    /// Fails the check.
    error,
    /// Printed, but doesn't fail the check.
    warn,
    /// Not run.
    off,
}

/// The `nullAudit` section.
struct NullAudit
{
    /// The test module that imports every module and runs `auditModules`.
    string module_;
    /// Modules it can't import (the main module audits itself).
    string[] skip;
}

/// A parsed `safe-d.json`.
struct Config
{
    string[] sources = ["source"];
    string[] exclude;
    string[] ioModules;
    string[] testFiles = ["*_test.d"];
    string[] subtractionScope;
    Option!NullAudit nullAudit;
    string[][string] allow;
    Severity[string] rules;
    long[string] budgets;
    string[] dubFiles = ["dub.json"];
    bool requireHook = true;

    /// The budget named `name` (0 when missing).
    long budget(string name) const
    {
        if (auto p = name in budgets) return *p;
        return 0;
    }

    /// How rule `id` reports (error unless configured).
    Severity severity(string id) const
    {
        if (auto p = id in rules) return *p;
        return Severity.error;
    }

    /// Whether `path` is exempt from rule `id`.
    bool allowed(string id, string path) const
    {
        if (auto p = id in allow)
            return underAny(path, *p);
        return false;
    }

    /// Whether `path` is one of the io modules.
    bool isIo(string path) const { return underAny(path, ioModules); }

    /// Whether `path` is a test file (by its base name).
    bool isTest(string path) const
    {
        import std.path : baseName, globMatch;
        foreach (g; testFiles)
            if (globMatch(baseName(path), g)) return true;
        return false;
    }
}

/// `path` is `prefix` or lies under it (both relative, `/`-separated).
bool under(string path, string prefix) pure nothrow @nogc
{
    if (prefix.length && prefix[$ - 1] == '/') prefix = prefix[0 .. $ - 1];
    return path == prefix || (path.length > prefix.length && path[0 .. prefix.length] == prefix
        && path[prefix.length] == '/');
}

/// `path` is under one of `prefixes`.
bool underAny(string path, const string[] prefixes) pure nothrow @nogc
{
    foreach (p; prefixes)
        if (under(path, p)) return true;
    return false;
}

/// Thrown for a malformed `safe-d.json`.
class ConfigException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(msg, file, line);
    }
}

private string[] strings(const ref JSONValue v, string key)
{
    string[] r;
    if (v.type != JSONType.array) throw new ConfigException("`" ~ key ~ "` must be an array of strings");
    foreach (e; v.arrayNoRef)
    {
        if (e.type != JSONType.string) throw new ConfigException("`" ~ key ~ "` must be an array of strings");
        r ~= normalisePath(e.str);
    }
    return r;
}

/// A path as the checker compares it: `/`-separated, no leading `./`, so a
/// safe-d.json written on Windows (`source\\app\\io.d`) means the same.
string normalisePath(string p) pure
{
    import std.array : replace;
    import std.string : startsWith;

    auto r = p.replace("\\", "/");
    while (r.startsWith("./")) r = r[2 .. $];
    return r;
}

unittest
{
    assert(normalisePath(`source\app\io.d`) == "source/app/io.d");
    assert(normalisePath(`.\source`) == "source" && normalisePath("./source/") == "source/");
    auto c = parseConfig(`{"ioModules":["src\\io.d"],"allow":{"SD020":[".\\src\\gen"]}}`);
    assert(c.isIo("src/io.d") && c.allowed("SD020", "src/gen/x.d"));
}

/// Parse `safe-d.json` text.
Config parseConfig(string text)
{
    import std.conv : to;
    import std.regex : matchFirst, regex;

    Config c;
    const root = parseJSON(text);
    if (root.type != JSONType.object) throw new ConfigException("safe-d.json must hold an object");
    static immutable known = ["$schema", "sources", "exclude", "ioModules", "testFiles", "subtractionScope",
        "nullAudit", "allow", "rules", "budgets", "dubFiles", "requireHook"];
    foreach (k, _; root.objectNoRef)
    {
        import std.algorithm : canFind;
        if (!known.canFind(k)) throw new ConfigException("unknown key `" ~ k ~ "` in safe-d.json");
    }
    if (auto v = jsonGet(root, "sources")) c.sources = strings(*v, "sources");
    if (auto v = jsonGet(root, "exclude")) c.exclude = strings(*v, "exclude");
    if (auto v = jsonGet(root, "ioModules")) c.ioModules = strings(*v, "ioModules");
    if (auto v = jsonGet(root, "testFiles")) c.testFiles = strings(*v, "testFiles");
    if (auto v = jsonGet(root, "subtractionScope")) c.subtractionScope = strings(*v, "subtractionScope");
    if (auto v = jsonGet(root, "dubFiles")) c.dubFiles = strings(*v, "dubFiles");
    if (auto v = jsonGet(root, "requireHook"))
    {
        if (v.type != JSONType.true_ && v.type != JSONType.false_)
            throw new ConfigException("`requireHook` must be true or false");
        c.requireHook = v.type == JSONType.true_;
    }
    if (auto v = jsonGet(root, "nullAudit"))
    {
        NullAudit na;
        if (auto m = jsonGet(*v, "module"))
        {
            if (m.type != JSONType.string) throw new ConfigException("`nullAudit.module` must be a string");
            na.module_ = m.str;
        }
        else throw new ConfigException("`nullAudit` needs a `module`");
        if (auto s = jsonGet(*v, "skip")) na.skip = strings(*s, "nullAudit.skip");
        c.nullAudit = some(na);
    }
    auto ruleId = regex(`^SD\d{3}$`);
    if (auto v = jsonGet(root, "allow"))
    {
        if (v.type != JSONType.object) throw new ConfigException("`allow` must map rule ids to paths");
        foreach (k, e; v.objectNoRef)
        {
            if (!matchFirst(k, ruleId)) throw new ConfigException("`allow`: `" ~ k ~ "` is not a rule id (SD000)");
            c.allow[k] = strings(e, "allow." ~ k);
        }
    }
    if (auto v = jsonGet(root, "rules"))
    {
        if (v.type != JSONType.object) throw new ConfigException("`rules` must map rule ids to error/warn/off");
        foreach (k, e; v.objectNoRef)
        {
            if (!matchFirst(k, ruleId)) throw new ConfigException("`rules`: `" ~ k ~ "` is not a rule id (SD000)");
            if (e.type != JSONType.string) throw new ConfigException("`rules." ~ k ~ "` must be error, warn or off");
            switch (e.str)
            {
                case "error": c.rules[k] = Severity.error; break;
                case "warn": c.rules[k] = Severity.warn; break;
                case "off": c.rules[k] = Severity.off; break;
                default: throw new ConfigException("`rules." ~ k ~ "` must be error, warn or off");
            }
        }
    }
    if (auto v = jsonGet(root, "budgets"))
    {
        if (v.type != JSONType.object) throw new ConfigException("`budgets` must map names to counts");
        foreach (k, e; v.objectNoRef)
        {
            if (e.type != JSONType.integer && e.type != JSONType.uinteger)
                throw new ConfigException("`budgets." ~ k ~ "` must be a whole number");
            immutable n = e.type == JSONType.integer ? e.integer : e.uinteger.to!long;
            if (n < 0) throw new ConfigException("`budgets." ~ k ~ "` can't be negative");
            c.budgets[k] = n;
        }
    }
    return c;
}

/// `c` as `safe-d.json` text: fixed key order, sorted maps, two-space
/// indent, so rewriting it (`adopt`, `--ratchet`) gives a small diff.
string renderConfig(const ref Config c)
{
    import std.algorithm : sort;
    import std.array : appender, array;
    import std.conv : to;

    auto o = appender!string;
    string q(string s) { return JSONValue(s).toString(JSONOptions.doNotEscapeSlashes); }
    string list(const string[] xs)
    {
        string r = "[";
        foreach (i, x; xs) r ~= (i ? ", " : "") ~ q(x);
        return r ~ "]";
    }
    string[] parts;
    parts ~= `  "sources": ` ~ list(c.sources);
    if (c.exclude.length) parts ~= `  "exclude": ` ~ list(c.exclude);
    if (c.ioModules.length) parts ~= `  "ioModules": ` ~ list(c.ioModules);
    if (c.testFiles != ["*_test.d"]) parts ~= `  "testFiles": ` ~ list(c.testFiles);
    if (c.subtractionScope.length) parts ~= `  "subtractionScope": ` ~ list(c.subtractionScope);
    foreach (na; c.nullAudit)
        parts ~= `  "nullAudit": { "module": ` ~ q(na.module_)
            ~ (na.skip.length ? `, "skip": ` ~ list(na.skip) : "") ~ " }";
    if (c.allow.length)
    {
        string s = "  \"allow\": {\n";
        auto keys = c.allow.keys.array;
        keys.sort;
        foreach (i, k; keys) s ~= "    " ~ q(k) ~ ": " ~ list(c.allow[k]) ~ (i + 1 < keys.length ? ",\n" : "\n");
        parts ~= s ~ "  }";
    }
    if (c.rules.length)
    {
        string s = "  \"rules\": {\n";
        auto keys = c.rules.keys.array;
        keys.sort;
        foreach (i, k; keys) s ~= "    " ~ q(k) ~ ": " ~ q(c.rules[k].to!string) ~ (i + 1 < keys.length ? ",\n" : "\n");
        parts ~= s ~ "  }";
    }
    if (c.dubFiles != ["dub.json"]) parts ~= `  "dubFiles": ` ~ list(c.dubFiles);
    if (!c.requireHook) parts ~= `  "requireHook": false`;
    {
        string s = "  \"budgets\": {\n";
        auto keys = c.budgets.keys.array;
        keys.sort;
        foreach (i, k; keys) s ~= "    " ~ q(k) ~ ": " ~ c.budgets[k].to!string ~ (i + 1 < keys.length ? ",\n" : "\n");
        parts ~= s ~ "  }";
    }
    o ~= "{\n";
    foreach (i, p; parts) o ~= p ~ (i + 1 < parts.length ? ",\n" : "\n");
    o ~= "}\n";
    return o[];
}

unittest
{
    auto c = parseConfig(`{"sources":["src"],"ioModules":["src/io.d"],"budgets":{"catch":3},
        "rules":{"SD020":"warn"},"allow":{"SD010":["src/arith.d"]},"nullAudit":{"module":"src/na_test.d"}}`);
    assert(c.sources == ["src"] && c.isIo("src/io.d") && !c.isIo("src/io.dx"));
    assert(c.budget("catch") == 3 && c.budget("trusted") == 0);
    assert(c.severity("SD020") == Severity.warn && c.severity("SD001") == Severity.error);
    assert(c.allowed("SD010", "src/arith.d") && !c.allowed("SD011", "src/arith.d"));
    assert(c.isTest("src/x/foo_test.d") && !c.isTest("src/test.d"));
    assert(c.nullAudit.isSome);
    // Round trip.
    auto again = parseConfig(renderConfig(c));
    assert(again.sources == c.sources && again.budgets == c.budgets && again.rules == c.rules);
    assert(again.allow == c.allow && again.nullAudit.isSome);
}

unittest
{
    import std.exception : assertThrown;
    assertThrown!ConfigException(parseConfig(`{"budget":{}}`));
    assertThrown!ConfigException(parseConfig(`{"rules":{"X1":"warn"}}`));
    assertThrown!ConfigException(parseConfig(`{"rules":{"SD001":"maybe"}}`));
    assertThrown!ConfigException(parseConfig(`{"budgets":{"catch":-1}}`));
    assertThrown!ConfigException(parseConfig(`[]`));
    assert(under("a/b.d", "a") && under("a", "a/") && !under("ab/c.d", "a"));
}
