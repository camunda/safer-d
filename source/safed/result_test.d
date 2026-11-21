/// Tests of `safed.result` from outside the module, where `private` applies:
/// the value and error are reachable only through the accessors.
module safed.result_test;

@safe:

import safed.result;
import safed.option : None;

private alias IntResult = Result!(int, string);

private IntResult parse(string s) nothrow
{
    return s == "1" ? IntResult.ok(1) : IntResult.err("not a number: " ~ s);
}

private class Thing
{
    int n;
    this(int n) { this.n = n; }
}

unittest
{
    alias R = Result!(int, string);
    auto r = R.ok(1);
    assert(!__traits(compiles, r.value));
    assert(!__traits(compiles, r.error));
    assert(!__traits(compiles, r.success = false));
    assert(!__traits(compiles, { R x; x.value = 2; }));
    assert(r.isOk);
}

// Ignoring a Result is a compile error; cast(void) discards on purpose.
unittest
{
    assert(!__traits(compiles, { parse("1"); }));
    assert(__traits(compiles, { cast(void) parse("1"); }));
}

// Class values: never null.
unittest
{
    auto r = Result!(Thing, string).ok(new Thing(4));
    assert(r.map!(t => t.n).unwrap("ok") == 4);
}

// attempt bridges throwing code; it is nothrow.
unittest
{
    import std.conv : to;

    static int toInt(string s) { return s.to!int; }
    auto good = attempt!toInt("42");
    static assert(is(typeof(good) == Result!(int, Exception)));
    assert(good.unwrap("parses") == 42);
    assert(attempt!toInt("nope").isErr);

    static void boom() { throw new Exception("boom"); }
    auto v = attempt!boom();
    static assert(is(typeof(v) == Result!(None, Exception)));
    assert(v.unwrapErr("throws").msg == "boom");

    static void quiet() {}
    assert(attempt!quiet().isOk);

    static assert(is(typeof(() nothrow { cast(void) attempt!toInt("1"); })));
}

// A throwing foreach body still works outside nothrow code.
unittest
{
    static void throwing()
    {
        foreach (v; parse("1")) if (v == 1) throw new Exception("one");
    }
    bool threw;
    try throwing(); catch (Exception) threw = true;
    assert(threw);
}
