/// safe-d-check: checks a D project against the Safe D rules.
///
/// ---
/// safe-d-check [check] [--root DIR] [--format text|github] [--ratchet]
/// safe-d-check adopt   [--root DIR]
/// safe-d-check init    DIR [--name NAME]
/// safe-d-check rules
/// ---
module safed.check.app;

@safe:

import std.algorithm : sort, startsWith;
import std.array : array, replace;
import std.conv : to;
import std.file : exists, isDir, isFile, readText, write;
import std.format : format;
import std.path : buildPath, baseName, extension, relativePath, absolutePath, buildNormalizedPath;
import safed.io : stdOut, stdErr, listDir;
import safed.option : Option, some, none;
import safed.check.config;
import safed.check.rules;
import safed.check.scaffold : scaffold;
import safed.check.version_ : toolVersion;

private enum usage = `safe-d-check ` ~ toolVersion ~ `: check a D project against the Safe D rules

Usage:
  safe-d-check [check] [--root DIR] [--format text|github] [--ratchet]
      Check the project at DIR (default: .). Exit 1 on a violation or a
      budget overrun. --ratchet lowers budgets the code now comes in under.
  safe-d-check adopt [--root DIR]
      Measure the project and write safe-d.json with budgets at today's
      counts, so the rules hold from here on without a big-bang cleanup.
  safe-d-check init DIR [--name NAME]
      Create a new Safe D project in DIR.
  safe-d-check rules
      List the rules.
  safe-d-check --version
`;

/// Output style.
enum Format { text, github }

/// Parsed command line.
struct Args
{
    string command = "check";
    string root = ".";
    Format format;
    bool ratchet;
    string dir;
    string name;
}

/// Thrown for a bad command line.
class UsageException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow { super(msg, file, line); }
}

/// Parse `argv` (without the program name).
Args parseArgs(const string[] argv)
{
    Args a;
    bool sawCommand;
    for (size_t i = 0; i < argv.length; i++)
    {
        immutable arg = argv[i];
        string value(string flag)
        {
            if (arg.startsWith(flag ~ "=")) return arg[flag.length + 1 .. $];
            if (i + 1 >= argv.length) throw new UsageException(flag ~ " needs a value");
            return argv[++i];
        }
        if (arg == "--root" || arg.startsWith("--root=")) a.root = value("--root");
        else if (arg == "--name" || arg.startsWith("--name=")) a.name = value("--name");
        else if (arg == "--format" || arg.startsWith("--format="))
        {
            switch (value("--format"))
            {
                case "text": a.format = Format.text; break;
                case "github": a.format = Format.github; break;
                default: throw new UsageException("--format is text or github");
            }
        }
        else if (arg == "--ratchet") a.ratchet = true;
        else if (arg == "--version" || arg == "-v") a.command = "version";
        else if (arg == "--help" || arg == "-h") a.command = "help";
        else if (arg.startsWith("-")) throw new UsageException("unknown flag " ~ arg);
        else if (!sawCommand && ["check", "adopt", "init", "rules", "help", "version"].canFindStr(arg))
        {
            a.command = arg;
            sawCommand = true;
        }
        else if (a.command == "init" && !a.dir.length) a.dir = arg;
        else throw new UsageException("unexpected argument " ~ arg);
    }
    if (a.command == "init" && !a.dir.length) throw new UsageException("init needs a directory");
    return a;
}

private bool canFindStr(const string[] xs, string x) pure nothrow @nogc
{
    foreach (s; xs) if (s == x) return true;
    return false;
}

/// The project's `.d` files, lexed, with `/`-separated paths relative to `root`.
Source[] collect(string root, const ref Config cfg)
{
    import std.file : SpanMode;
    Source[] files;
    foreach (dir; cfg.sources)
    {
        auto full = buildPath(root, dir);
        if (!exists(full) || !isDir(full)) continue;
        foreach (e; listDir(full, SpanMode.depth))
        {
            if (!e.isFile || extension(e.name) != ".d") continue;
            auto rel = relativePath(absolutePath(e.name), absolutePath(root)).replace("\\", "/");
            if (underAny(rel, cfg.exclude)) continue;
            files ~= source(rel, readText(e.name));
        }
    }
    files.sort!((a, b) => a.path < b.path);
    return files;
}

/// The dub.json texts named in the config, by relative path.
string[string] dubFiles(string root, const ref Config cfg)
{
    string[string] r;
    foreach (f; cfg.dubFiles)
    {
        auto full = buildPath(root, f);
        if (exists(full) && isFile(full)) r[f] = readText(full);
    }
    return r;
}

/// `safe-d.json` under `root`, or the defaults when there is none.
Config loadConfig(string root, out bool found)
{
    auto p = buildPath(root, "safe-d.json");
    found = exists(p);
    return found ? parseConfig(readText(p)) : Config.init;
}

private void emit(Format fmt, string level, string rule, string file, size_t line, string msg)
{
    if (fmt == Format.github)
        stdOut.writefln("::%s file=%s,line=%s,title=%s::%s", level == "Error" ? "error" : "warning", file, line, rule, msg);
    else
        stdErr.writefln("%s(%s): %s: %s %s", file, line, level, rule, msg);
}

/// Run `check`; the exit status.
int runCheck(const ref Args a)
{
    bool found;
    auto cfg = loadConfig(a.root, found);
    if (!found)
        stdErr.writeln("safe-d-check: no safe-d.json in " ~ a.root ~ "; using the defaults (every budget 0). "
            ~ "`safe-d-check adopt` writes one.");
    auto files = collect(a.root, cfg);
    if (!files.length)
    {
        stdErr.writeln("safe-d-check: no .d files under " ~ format("%-(%s, %)", cfg.sources));
        return 2;
    }
    auto res = runRules(cfg, files, dubFiles(a.root, cfg));
    bool failed;
    foreach (f; res.findings)
    {
        immutable sev = cfg.severity(f.rule);
        immutable level = sev == Severity.error ? "Error" : "Warning";
        if (sev == Severity.error) failed = true;
        emit(a.format, level, f.rule, f.file, f.line, f.message);
    }
    bool lowered;
    foreach (c; res.counts)
    {
        immutable budget = cfg.budget(c.budget);
        if (c.count > budget)
        {
            immutable sev = cfg.severity(c.rule);
            immutable level = sev == Severity.error ? "Error" : "Warning";
            if (sev == Severity.error) failed = true;
            emit(a.format, level, c.rule, "safe-d.json", 1, format(
                "%s %s, budget is %s (budgets.%s); make the code safe, or justify the escape and raise the budget",
                c.count, c.what, budget, c.budget));
            foreach (w; c.where) stdErr.writeln("  counted: " ~ w);
        }
        else if (c.count < budget)
        {
            if (a.ratchet)
            {
                cfg.budgets[c.budget] = c.count;
                lowered = true;
                stdErr.writefln("safe-d-check: lowered budgets.%s from %s to %s", c.budget, budget, c.count);
            }
            else
                stdErr.writefln("safe-d-check: %s %s, below the budget of %s; lower budgets.%s to %s (or run with --ratchet)",
                    c.count, c.what, budget, c.budget, c.count);
        }
    }
    if (lowered) write(buildPath(a.root, "safe-d.json"), renderConfig(cfg));
    if (!failed)
        stdErr.writefln("safe-d-check: %s files clean (%s rules)", files.length, allRules.length);
    return failed ? 1 : 0;
}

/// Run `adopt`: write safe-d.json with budgets at today's counts.
int runAdopt(const ref Args a)
{
    bool found;
    auto cfg = loadConfig(a.root, found);
    if (!found)
    {
        // First adoption: find the usual io and null-audit modules.
        Config probe;
        foreach (f; collect(a.root, probe))
        {
            if (baseName(f.path) == "safeio.d") cfg.ioModules ~= f.path;
            if (baseName(f.path) == "null_audit_test.d") cfg.nullAudit = some(NullAudit(f.path, null));
        }
    }
    auto files = collect(a.root, cfg);
    auto res = runRules(cfg, files, dubFiles(a.root, cfg));
    foreach (c; res.counts) cfg.budgets[c.budget] = c.count;
    write(buildPath(a.root, "safe-d.json"), renderConfig(cfg));
    stdErr.writefln("safe-d-check: wrote %s with budgets at today's counts:", buildPath(a.root, "safe-d.json"));
    foreach (c; res.counts) stdErr.writefln("  %-14s %5s  %s", c.budget, c.count, c.rule);
    if (res.findings.length)
    {
        stdErr.writefln("%s violations still to fix (budgets can't absorb these):", res.findings.length);
        foreach (f; res.findings) emit(Format.text, "Error", f.rule, f.file, f.line, f.message);
        return 1;
    }
    return 0;
}

/// Entry point, separate from `main` for tests.
int run(const string[] argv)
{
    Args a;
    try a = parseArgs(argv);
    catch (UsageException e)
    {
        stdErr.writeln("safe-d-check: " ~ e.msg ~ "\n\n" ~ usage);
        return 2;
    }
    try
    {
        final switch (commandOf(a.command))
        {
            case Command.help: stdOut.write(usage); return 0;
            case Command.version_: stdOut.writeln(toolVersion); return 0;
            case Command.rules:
                foreach (r; allRules)
                    stdOut.writefln("%s  %-14s %s", r.id, r.budget.length ? r.budget : "-", r.title);
                return 0;
            case Command.check: return runCheck(a);
            case Command.adopt: return runAdopt(a);
            case Command.init_: return scaffold(a.dir, a.name);
        }
    }
    catch (ConfigException e)
    {
        stdErr.writeln("safe-d-check: safe-d.json: " ~ e.msg);
        return 2;
    }
    catch (Exception e)
    {
        stdErr.writeln("safe-d-check: " ~ e.msg);
        return 2;
    }
}

private enum Command { help, version_, rules, check, adopt, init_ }

private Command commandOf(string s) pure
{
    switch (s)
    {
        case "help": return Command.help;
        case "version": return Command.version_;
        case "rules": return Command.rules;
        case "adopt": return Command.adopt;
        case "init": return Command.init_;
        case "check": return Command.check;
        default: assert(0, "parseArgs accepted an unknown command " ~ s);
    }
}

version (unittest) {} else
int main(string[] argv)
{
    return run(argv[1 .. $]);
}

unittest
{
    import std.exception : assertThrown;
    auto a = parseArgs(["--root", "x", "--ratchet", "--format=github"]);
    assert(a.command == "check" && a.root == "x" && a.ratchet && a.format == Format.github);
    assert(parseArgs(["adopt", "--root=y"]).command == "adopt");
    auto i = parseArgs(["init", "proj", "--name", "p"]);
    assert(i.dir == "proj" && i.name == "p");
    assertThrown!UsageException(parseArgs(["init"]));
    assertThrown!UsageException(parseArgs(["--nope"]));
    assertThrown!UsageException(parseArgs(["check", "extra"]));
}
