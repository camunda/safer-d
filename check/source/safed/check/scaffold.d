/// `safe-d-check init`: a new project that passes every rule from its first
/// commit (all budgets 0). The templates are compiled in (`templates/`), so
/// init needs no network.
module safed.check.scaffold;

@safe:

import std.array : replace;
import std.file : exists, isDir, mkdirRecurse, write;
import std.path : baseName, buildPath, absolutePath, buildNormalizedPath, dirName;
import safed.io : stdErr, listDir;
import safed.check.version_ : toolVersion;

private struct Template { string path; string text; }

private static immutable Template[] templates = [
    Template("dub.json", import("dub.json")),
    Template("safe-d.json", import("safe-d.json")),
    Template("dscanner.ini", import("dscanner.ini")),
    Template("Makefile", import("Makefile")),
    Template(".gitignore", import("gitignore")),
    Template(".github/workflows/ci.yml", import("ci.yml")),
    Template("source/app.d", import("app.d")),
    Template("source/{{module}}/greet.d", import("greet.d")),
    Template("source/{{module}}/null_audit_test.d", import("null_audit_test.d")),
];

/// The dub package name for `name`: lower case, `-` for anything else.
string packageName(string name) pure
{
    import std.ascii : isAlphaNum, toLower;
    string r;
    foreach (char c; name) r ~= isAlphaNum(c) ? toLower(c) : '-';
    return r;
}

/// The D module name for a package name (`-` becomes `_`).
string moduleName(string pkg) pure
{
    return pkg.replace("-", "_");
}

/// The dependency spec new projects use: this release, or any when unreleased.
string dependencySpec(string ver) pure
{
    return ver == "0.0.0-dev" ? "*" : "~>" ~ ver;
}

/// `text` with the `{{...}}` placeholders filled in.
string fill(string text, string pkg, string ver) pure
{
    import std.string : split;
    immutable major = ver.split(".")[0];
    return text.replace("{{name}}", pkg).replace("{{module}}", moduleName(pkg))
        .replace("{{version}}", dependencySpec(ver)).replace("{{major}}", major);
}

/// Write a new project into `dir` (which must be empty or missing).
int scaffold(string dir, string name)
{
    if (exists(dir) && (!isDir(dir) || listDir(dir, imported!"std.file".SpanMode.shallow).length))
    {
        stdErr.writeln("safe-d-check init: " ~ dir ~ " exists and isn't empty");
        return 2;
    }
    auto pkg = packageName(name.length ? name : baseName(buildNormalizedPath(absolutePath(dir))));
    foreach (t; templates)
    {
        auto path = buildPath(dir, fill(t.path, pkg, toolVersion));
        mkdirRecurse(dirName(path));
        write(path, fill(t.text, pkg, toolVersion));
    }
    stdErr.writeln("safe-d-check init: created " ~ pkg ~ " in " ~ dir ~ "\n"
        ~ "  cd " ~ dir ~ " && dub test && dub run");
    return 0;
}

unittest
{
    assert(packageName("My App") == "my-app");
    assert(moduleName("my-app") == "my_app");
    assert(dependencySpec("0.0.0-dev") == "*" && dependencySpec("1.2.3") == "~>1.2.3");
    assert(fill("{{name}} {{module}} {{version}} v{{major}}", "a-b", "1.2.3") == "a-b a_b ~>1.2.3 v1");
}
