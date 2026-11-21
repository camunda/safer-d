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
///   "requireHook": true,
///   "projectRules": [
///     { "id": "P001", "kind": "ban", "pattern": "\\bsetlocale\\b", "message": "keep the C locale" }
///   ]
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

/// What a project rule does with its matches.
enum Kind
{
    /// Each match is a finding.
    ban,
    /// Matches are counted against `budgets[budget]`.
    budget,
    /// Matches are counted, and the count may only go up.
    floor,
    /// Every module with a line matching `select` is imported by `listIn`.
    listed,
}

/// One entry of `projectRules`: a project-specific check that isn't a Safe D
/// rule. Patterns match code (comments and string contents removed).
struct ProjectRule
{
    /// `P` and three digits.
    string id;
    Kind kind;
    /// The regex counted or banned (ban, budget, floor).
    string pattern;
    /// The regex that picks the modules to list (listed).
    string select;
    /// The module that must import them (listed).
    string listIn;
    /// Also report `static import`s in `listIn` of modules that don't match
    /// `select` (listed).
    bool exact;
    /// The budget name (budget).
    string budget;
    /// The lowest allowed count (floor).
    long floor;
    /// Paths the rule skips.
    string[] except;
    /// When set, the only paths the rule reads.
    string[] only;
    /// Whether test files count.
    bool testFiles;
    string message;

    /// Whether the rule reads `path` (a test file when `test`).
    bool covers(string path, bool test) const
    {
        if (test && !testFiles) return false;
        if (only.length && !underAny(path, only)) return false;
        return !underAny(path, except);
    }
}

/// Rules that are new and report as warnings unless configured.
static immutable string[] warnByDefault = ["SD023", "SD024"];

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
    ProjectRule[] projectRules;

    /// The budget named `name` (0 when missing).
    long budget(string name) const
    {
        if (auto p = name in budgets) return *p;
        return 0;
    }

    /// How rule `id` reports (error unless configured).
    Severity severity(string id) const
    {
        import std.algorithm : canFind;
        if (auto p = id in rules) return *p;
        return warnByDefault.canFind(id) ? Severity.warn : Severity.error;
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
    auto n = parseConfig(`{"nullAudit":{"module":".\\src\\na_test.d"}}`);
    bool seen;
    foreach (na; n.nullAudit) seen = na.module_ == "src/na_test.d";
    assert(seen);
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
        "nullAudit", "allow", "rules", "budgets", "dubFiles", "requireHook", "projectRules"];
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
            na.module_ = normalisePath(m.str);
        }
        else throw new ConfigException("`nullAudit` needs a `module`");
        if (auto s = jsonGet(*v, "skip")) na.skip = strings(*s, "nullAudit.skip");
        c.nullAudit = some(na);
    }
    auto ruleId = regex(`^(SD|P)\d{3}$`);
    if (auto v = jsonGet(root, "allow"))
    {
        if (v.type != JSONType.object) throw new ConfigException("`allow` must map rule ids to paths");
        foreach (k, e; v.objectNoRef)
        {
            if (!matchFirst(k, ruleId)) throw new ConfigException("`allow`: `" ~ k ~ "` is not a rule id (SD000 or P000)");
            c.allow[k] = strings(e, "allow." ~ k);
        }
    }
    if (auto v = jsonGet(root, "rules"))
    {
        if (v.type != JSONType.object) throw new ConfigException("`rules` must map rule ids to error/warn/off");
        foreach (k, e; v.objectNoRef)
        {
            if (!matchFirst(k, ruleId)) throw new ConfigException("`rules`: `" ~ k ~ "` is not a rule id (SD000 or P000)");
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
    if (auto v = jsonGet(root, "projectRules")) c.projectRules = projectRules(*v);
    return c;
}

private ProjectRule[] projectRules(const ref JSONValue v)
{
    import std.algorithm : canFind;
    import std.conv : to;
    import std.regex : matchFirst, regex, RegexException;

    if (v.type != JSONType.array) throw new ConfigException("`projectRules` must be an array of objects");
    ProjectRule[] out_;
    static immutable keys = ["id", "kind", "pattern", "select", "listIn", "exact", "budget", "floor",
        "except", "only", "testFiles", "message"];
    foreach (e; v.arrayNoRef)
    {
        if (e.type != JSONType.object) throw new ConfigException("`projectRules` must be an array of objects");
        ProjectRule p;
        string str(string k, bool required)
        {
            if (auto x = jsonGet(e, k))
            {
                if (x.type != JSONType.string) throw new ConfigException("`projectRules`: `" ~ k ~ "` must be a string");
                return x.str;
            }
            if (required)
                throw new ConfigException("`projectRules`: " ~ (p.id.length ? p.id ~ " " : "") ~ "needs `" ~ k ~ "`");
            return null;
        }
        bool flag(string k)
        {
            if (auto x = jsonGet(e, k))
            {
                if (x.type != JSONType.true_ && x.type != JSONType.false_)
                    throw new ConfigException("`projectRules`: `" ~ k ~ "` must be true or false");
                return x.type == JSONType.true_;
            }
            return false;
        }
        void checkRegex(string what, string re)
        {
            try regex(re);
            catch (RegexException ex)
                throw new ConfigException("`projectRules`: " ~ p.id ~ " `" ~ what ~ "` is not a valid regex: " ~ ex.msg);
        }
        p.id = str("id", true);
        if (!matchFirst(p.id, regex(`^P\d{3}$`)))
            throw new ConfigException("`projectRules`: `" ~ p.id ~ "` is not a project rule id (P000)");
        foreach (k, _; e.objectNoRef)
            if (!keys.canFind(k)) throw new ConfigException("`projectRules`: " ~ p.id ~ " has unknown key `" ~ k ~ "`");
        foreach (q; out_)
            if (q.id == p.id) throw new ConfigException("`projectRules`: duplicate id " ~ p.id);
        switch (str("kind", true))
        {
            case "ban": p.kind = Kind.ban; break;
            case "budget": p.kind = Kind.budget; break;
            case "floor": p.kind = Kind.floor; break;
            case "listed": p.kind = Kind.listed; break;
            default: throw new ConfigException("`projectRules`: " ~ p.id ~ " `kind` must be ban, budget, floor or listed");
        }
        p.message = str("message", true);
        // Keys that belong to the kind; the others are mistakes.
        string[] allowed;
        final switch (p.kind)
        {
            case Kind.ban: allowed = ["pattern"]; break;
            case Kind.budget: allowed = ["pattern", "budget"]; break;
            case Kind.floor: allowed = ["pattern", "floor"]; break;
            case Kind.listed: allowed = ["select", "listIn", "exact"]; break;
        }
        foreach (k; ["pattern", "budget", "floor", "select", "listIn", "exact"])
            if (!allowed.canFind(k) && jsonGet(e, k))
                throw new ConfigException("`projectRules`: " ~ p.id ~ " `" ~ k ~ "` doesn't apply to kind "
                    ~ p.kind.to!string);
        if (p.kind == Kind.listed)
        {
            p.select = str("select", true);
            checkRegex("select", p.select);
            p.listIn = normalisePath(str("listIn", true));
            p.exact = flag("exact");
        }
        else
        {
            p.pattern = str("pattern", true);
            checkRegex("pattern", p.pattern);
        }
        if (p.kind == Kind.budget) p.budget = str("budget", true);
        if (p.kind == Kind.floor)
        {
            auto f = jsonGet(e, "floor");
            if (!f) throw new ConfigException("`projectRules`: " ~ p.id ~ " needs `floor`");
            if (f.type != JSONType.integer && f.type != JSONType.uinteger)
                throw new ConfigException("`projectRules`: " ~ p.id ~ " `floor` must be a whole number");
            p.floor = f.type == JSONType.integer ? f.integer : f.uinteger.to!long;
            if (p.floor < 0) throw new ConfigException("`projectRules`: " ~ p.id ~ " `floor` can't be negative");
        }
        if (auto x = jsonGet(e, "except")) p.except = strings(*x, "projectRules." ~ p.id ~ ".except");
        if (auto x = jsonGet(e, "only")) p.only = strings(*x, "projectRules." ~ p.id ~ ".only");
        p.testFiles = flag("testFiles");
        out_ ~= p;
    }
    return out_;
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
    if (c.projectRules.length)
    {
        string s = "  \"projectRules\": [\n";
        foreach (i, p; c.projectRules)
        {
            string r = "    { \"id\": " ~ q(p.id) ~ ", \"kind\": " ~ q(p.kind.to!string);
            final switch (p.kind)
            {
                case Kind.ban: r ~= ", \"pattern\": " ~ q(p.pattern); break;
                case Kind.budget: r ~= ", \"pattern\": " ~ q(p.pattern) ~ ", \"budget\": " ~ q(p.budget); break;
                case Kind.floor: r ~= ", \"pattern\": " ~ q(p.pattern) ~ ", \"floor\": " ~ p.floor.to!string; break;
                case Kind.listed:
                    r ~= ", \"select\": " ~ q(p.select) ~ ", \"listIn\": " ~ q(p.listIn);
                    if (p.exact) r ~= ", \"exact\": true";
                    break;
            }
            if (p.except.length) r ~= ",\n      \"except\": " ~ list(p.except);
            if (p.only.length) r ~= ",\n      \"only\": " ~ list(p.only);
            if (p.testFiles) r ~= ", \"testFiles\": true";
            r ~= ",\n      \"message\": " ~ q(p.message) ~ " }";
            s ~= r ~ (i + 1 < c.projectRules.length ? ",\n" : "\n");
        }
        parts ~= s ~ "  ]";
    }
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

unittest // projectRules
{
    import std.exception : assertThrown;
    auto c = parseConfig(`{"rules":{"P002":"warn"},"allow":{"P001":["x"]},"projectRules":[
        {"id":"P001","kind":"ban","pattern":"\\bsetlocale\\b","except":["a.d"],"message":"m"},
        {"id":"P002","kind":"budget","pattern":"x","budget":"xs","only":["src"],"testFiles":true,"message":"m"},
        {"id":"P003","kind":"floor","pattern":"pure","floor":12,"message":"m"},
        {"id":"P004","kind":"listed","select":"^pure:","listIn":"src/p_test.d","exact":true,"message":"m"}]}`);
    assert(c.projectRules.length == 4 && c.projectRules[2].floor == 12 && c.projectRules[3].exact);
    assert(c.severity("P002") == Severity.warn && c.allowed("P001", "x/y.d"));
    assert(c.severity("SD023") == Severity.warn && c.severity("SD022") == Severity.error);
    assert(c.projectRules[0].covers("b.d", false) && !c.projectRules[0].covers("a.d", false)
        && !c.projectRules[0].covers("b_test.d", true));
    assert(c.projectRules[1].covers("src/t_test.d", true) && !c.projectRules[1].covers("lib/a.d", false));
    // Round trip.
    auto again = parseConfig(renderConfig(c));
    assert(again.projectRules == c.projectRules);

    string one(string body) { return `{"projectRules":[{"id":"P001","message":"m",` ~ body ~ `}]}`; }
    assertThrown!ConfigException(parseConfig(one(`"kind":"grep","pattern":"x"`)));       // unknown kind
    assertThrown!ConfigException(parseConfig(one(`"kind":"ban","pattern":"x","oops":1`))); // unknown key
    assertThrown!ConfigException(parseConfig(one(`"kind":"ban","pattern":"(x"`)));        // bad regex
    assertThrown!ConfigException(parseConfig(one(`"kind":"ban","pattern":"x","floor":1`))); // wrong kind's key
    assertThrown!ConfigException(parseConfig(one(`"kind":"floor","pattern":"x"`)));       // no floor
    assertThrown!ConfigException(parseConfig(one(`"kind":"listed","select":"x"`)));       // no listIn
    assertThrown!ConfigException(parseConfig(`{"projectRules":[{"id":"SD001","kind":"ban","pattern":"x","message":"m"}]}`));
    assertThrown!ConfigException(parseConfig(`{"projectRules":[{"id":"P001","kind":"ban","pattern":"x","message":"m"},
        {"id":"P001","kind":"ban","pattern":"y","message":"m"}]}`));                     // duplicate id
}
