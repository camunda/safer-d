/// `Result!(T, E)`: a function's success value or its error, in the
/// signature (Rust's `Result<T, E>`).
///
/// An exception doesn't appear in a function's type, so a caller can't see
/// what can go wrong or be made to handle it. A `Result` can:
///
/// - It is `@mustuse`: calling a function that returns one and ignoring the
///   value is a compile error. Discarding it on purpose takes
///   `cast(void) f();`, which safe-d-check counts (SD020).
/// - Its fields are private, so the only ways to the value are the ones
///   that handle the error too:
///   - `r.match!(v => ..., e => ...)`: both cases, or it doesn't compile;
///   - `foreach (e; r.take(v)) return typeof(return).err(e);`: Rust's `?`.
///     On success it stores the value in `v` and runs nothing; on error it
///     runs the body once with the error, usually to return it;
///   - `foreach (v; r) { ... }`: run a block only on success (`if let Ok`);
///   - `r.map!f`, `r.mapErr!f`, `r.andThen!f`, `r.orElse(fallback)`;
///   - `r.okOption` / `r.errOption` to an `Option`;
///   - `r.unwrap("why it can't fail")`, which halts with `assert(0)` (kept
///     in release builds) and is easy to grep for.
///
/// Mark the function `nothrow` as well, and the signature is the whole
/// story: the only way out of it with an error is the `Result`.
///
/// For a function with no success value, use `Result!(None, E)` and
/// `typeof(return).ok(none)`.
///
/// Neither side may be a null reference: `ok(null)` and `err(null)` halt at
/// the mistake, as `some(null)` does.
///
/// `attempt!f(args)` runs a function that throws and returns its outcome as
/// a `Result!(R, Exception)`, to bridge Phobos and other throwing code.
module safed.result;
@safe:

import core.attribute : mustuse;
import safed.option : None, none, Option, some;

/// Success (`T`) or failure (`E`). Construct with `Result!(T, E).ok(x)` or
/// `.err(e)`, or inside a function returning one, `typeof(return).ok(x)`.
@mustuse struct Result(T, E)
{
    private T value;
    private E error;
    private bool success;

    /// Success; halts if `x` is a null reference.
    static Result ok(T x)
    {
        noNull(x, "ok");
        Result r;
        r.value = x;
        r.success = true;
        return r;
    }

    /// Failure; halts if `e` is a null reference.
    static Result err(E e)
    {
        noNull(e, "err");
        Result r;
        r.error = e;
        return r;
    }

    /// `foreach (v; r) { ... }` runs the body once with the value on
    /// success: D's `if let Ok(v) = r`. The error is ignored, so prefer
    /// `match` or `take` unless that is intended.
    int opApply(scope int delegate(T) @safe dg)
    {
        return success ? dg(value) : 0;
    }

    /// ditto, usable in a `nothrow` function.
    int opApply(scope int delegate(T) @safe nothrow dg) nothrow
    {
        return success ? dg(value) : 0;
    }

    /// ditto, for a `const` or `immutable` Result.
    int opApply(scope int delegate(const T) @safe dg) const
    {
        return success ? dg(value) : 0;
    }

    /// ditto, `const` and `nothrow`.
    int opApply(scope int delegate(const T) @safe nothrow dg) const nothrow
    {
        return success ? dg(value) : 0;
    }

    bool isOk() const { return success; }

    bool isErr() const { return !success; }
}

private void noNull(X)(X x, string what)
{
    static if (is(X == class) || is(X == interface) || is(X : U*, U))
        if (x is null) assert(0, what ~ "(null): a Result holds no null " ~ X.stringof);
}

/// What `take` returns: iterates once over the error, if there is one.
struct Failure(E)
{
    private E error;
    private bool failed;

    int opApply(scope int delegate(E) @safe dg)
    {
        return failed ? dg(error) : 0;
    }

    /// ditto, usable in a `nothrow` function (the usual case for `take`).
    int opApply(scope int delegate(E) @safe nothrow dg) nothrow
    {
        return failed ? dg(error) : 0;
    }
}

/// Rust's `?`. On success, stores the value in `into` and the loop body
/// doesn't run; on error, the body runs once with the error:
///
/// ---
/// Result!(Config, string) load(string path) nothrow
/// {
///     string text;
///     foreach (e; readText(path).take(text)) return typeof(return).err(e);
///     ...
/// }
/// ---
///
/// `into` is left unchanged on error, so give it a value or don't read it
/// on that path. To change the error type on the way out, convert it in the
/// body: `return typeof(return).err(ConfigError(e));`.
Failure!E take(T, E)(Result!(T, E) r, ref T into)
{
    if (r.success)
    {
        into = r.value;
        return Failure!E.init;
    }
    return Failure!E(r.error, true);
}

/// Both cases: `r.match!(v => ..., e => ...)`. The two handlers return the
/// same type (or both nothing).
auto match(alias onOk, alias onErr, T, E)(Result!(T, E) r)
{
    return r.success ? onOk(r.value) : onErr(r.error);
}

/// Applies `f` to the value; the error passes through.
auto map(alias f, T, E)(Result!(T, E) r)
{
    alias U = typeof(f(r.value));
    return r.success ? Result!(U, E).ok(f(r.value)) : Result!(U, E).err(r.error);
}

/// Applies `f` to the error; the value passes through.
auto mapErr(alias f, T, E)(Result!(T, E) r)
{
    alias F = typeof(f(r.error));
    return r.success ? Result!(T, F).ok(r.value) : Result!(T, F).err(f(r.error));
}

/// Chains a step that can fail with the same error type: `f` takes the
/// value and returns a `Result!(U, E)`.
auto andThen(alias f, T, E)(Result!(T, E) r)
{
    alias R = typeof(f(r.value));
    static assert(is(R : Result!(U, E), U),
        "andThen: f must return a Result with error type " ~ E.stringof);
    return r.success ? f(r.value) : R.err(r.error);
}

/// The value, or `fallback` on error.
T orElse(T, E)(Result!(T, E) r, T fallback)
{
    return r.success ? r.value : fallback;
}

/// The value, as an `Option` (the error is dropped).
Option!T okOption(T, E)(Result!(T, E) r)
{
    return r.success ? some(r.value) : Option!T(none);
}

/// The error, as an `Option`.
Option!E errOption(T, E)(Result!(T, E) r)
{
    return r.success ? Option!E(none) : some(r.error);
}

/// The value; on error, halts with `why` and the error. For results that
/// can't fail here, with the reason it can't.
T unwrap(T, E)(Result!(T, E) r, string why)
{
    if (!r.success) assert(0, "unwrap: " ~ why ~ describe(r.error));
    return r.value;
}

/// The error; halts with `why` on success. For tests.
E unwrapErr(T, E)(Result!(T, E) r, string why)
{
    if (r.success) assert(0, "unwrapErr: " ~ why);
    return r.error;
}

private string describe(E)(E e)
{
    static if (is(E : const Exception))
        return ": " ~ e.msg;
    else static if (is(E : const(char)[]))
        return ": " ~ e.idup;
    else
        return " (" ~ E.stringof ~ ")";
}

/// Runs `f(args)` and returns its value, or the `Exception` it threw:
/// the bridge from throwing code. `Error`s (bugs) still propagate.
/// A `void` function gives `Result!(None, Exception)`.
auto attempt(alias f, Args...)(auto ref Args args) nothrow
{
    alias R = typeof(f(args));
    static if (is(R == void))
        alias Out = Result!(None, Exception);
    else
        alias Out = Result!(R, Exception);
    try
    {
        static if (is(R == void))
        {
            f(args);
            return Out.ok(none);
        }
        else
            return Out.ok(f(args));
    }
    catch (Exception e) // not swallowed: the exception is the Result's error
        return Out.err(e);
}

version (unittest)
{
    private alias IntResult = Result!(int, string);

    private IntResult parse(string s) nothrow
    {
        if (s == "1") return IntResult.ok(1);
        if (s == "2") return IntResult.ok(2);
        return IntResult.err("not a number: " ~ s);
    }

    private IntResult sumOf(string a, string b) nothrow
    {
        int x, y;
        foreach (e; parse(a).take(x)) return typeof(return).err(e);
        foreach (e; parse(b).take(y)) return typeof(return).err("second: " ~ e);
        return typeof(return).ok(x + y);
    }
}

// isOk and isErr (the fields are private: see result_test.d).
unittest
{
    assert(parse("1").isOk);
    assert(parse("x").isErr);
}

// take propagates like Rust's `?`, and the error type can be adapted.
unittest
{
    assert(sumOf("1", "2").unwrap("both parse") == 3);
    assert(sumOf("x", "2").unwrapErr("first fails") == "not a number: x");
    assert(sumOf("1", "y").unwrapErr("second fails") == "second: not a number: y");
}

// take leaves `into` alone on error.
unittest
{
    int v = 7;
    bool ran;
    foreach (e; parse("x").take(v)) ran = true;
    assert(ran && v == 7);
}

// match must handle both cases.
unittest
{
    assert(parse("2").match!(v => v * 10, e => -1) == 20);
    assert(parse("x").match!(v => v * 10, e => -1) == -1);
    assert(!__traits(compiles, parse("2").match!(v => v)));
}

// foreach runs only on success.
unittest
{
    int seen;
    foreach (v; parse("2")) seen = v;
    foreach (v; parse("x")) seen = -1;
    assert(seen == 2);

    const r = parse("1");
    foreach (v; r) seen = v;
    assert(seen == 1);

    static int inNothrow() nothrow
    {
        int n;
        foreach (v; parse("2")) n = v;
        const c = parse("1");
        foreach (v; c) n += v;
        return n;
    }
    assert(inNothrow() == 3);

}

// map, mapErr, andThen and orElse.
unittest
{
    assert(parse("2").map!(v => v * 3).unwrap("ok") == 6);
    assert(parse("x").map!(v => v * 3).isErr);

    auto len = parse("x").mapErr!(e => e.length);
    static assert(is(typeof(len) == Result!(int, size_t)));
    assert(len.unwrapErr("err") == "not a number: x".length);

    static IntResult half(int v) nothrow
    {
        return v % 2 == 0 ? IntResult.ok(v / 2) : IntResult.err("odd");
    }
    assert(parse("2").andThen!half.unwrap("even") == 1);
    assert(parse("1").andThen!half.unwrapErr("odd") == "odd");
    assert(parse("x").andThen!half.unwrapErr("first") == "not a number: x");

    assert(parse("x").orElse(9) == 9);
    assert(parse("1").orElse(9) == 1);
}

// To and from Option.
unittest
{
    int got;
    foreach (v; parse("2").okOption) got = v;
    assert(got == 2);
    assert(parse("x").okOption.isNone);
    assert(parse("1").errOption.isNone);
    string e;
    foreach (x; parse("x").errOption) e = x;
    assert(e == "not a number: x");
}

// A Result with no success value.
unittest
{
    static Result!(None, string) check(int n) nothrow
    {
        return n > 0 ? typeof(return).ok(none) : typeof(return).err("not positive");
    }
    assert(check(1).isOk);
    assert(check(0).unwrapErr("zero") == "not positive");
}

