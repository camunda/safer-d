/// A first module, to show the shape: `@safe:`, small functions, unittests.
module {{module}}.greet;

@safe:

import safed.option : Option, some, none;

/// "hello, <who>".
string greeting(string who) pure
{
    return "hello, " ~ who;
}

/// The first word of `s`, if there is one.
Option!string firstWord(string s) pure
{
    import std.string : split;
    auto words = s.split;
    return words.length ? some(words[0]) : Option!string(none);
}

unittest
{
    assert(greeting("d") == "hello, d");
    // An Option is read with `foreach`: the body runs only when a value is there.
    string got;
    foreach (w; firstWord("a b")) got = w;
    assert(got == "a");
    assert(firstWord("  ").isNone);
}
