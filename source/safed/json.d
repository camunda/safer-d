/// JSON and deep copies without `@system` access or `cast()` out of const.
module safed.json;

@safe:

import std.json : JSONValue, JSONType;
/// `v[key]` when `v` is an object holding it, else null. Phobos marks
/// `JSONValue.object` @system because it returns the AA by reference; this
/// only looks a key up and returns a pointer into the GC-owned table.
const(JSONValue)* jsonGet(return scope const ref JSONValue v, string key) @trusted
{
    if (v.type != JSONType.object) return null;
    return key in v.object;
}

/// A deep, mutable copy of `v`, so a `const` tree can be merged into a
/// mutable one without casting `const` away (and without the two sharing
/// subtrees). Numbers are copied as stored, never re-parsed.
JSONValue jsonCopy(const JSONValue v)
{
    final switch (v.type)
    {
        case JSONType.null_: return JSONValue(null);
        case JSONType.string: return JSONValue(v.str);
        case JSONType.integer: return JSONValue(v.integer);
        case JSONType.uinteger: return JSONValue(v.uinteger);
        case JSONType.float_: return JSONValue(v.floating);
        case JSONType.true_: return JSONValue(true);
        case JSONType.false_: return JSONValue(false);
        case JSONType.array:
            JSONValue[] a;
            foreach (e; v.arrayNoRef) a ~= jsonCopy(e);
            return JSONValue(a);
        case JSONType.object:
            JSONValue[string] o;
            foreach (k, e; v.objectNoRef) o[k] = jsonCopy(e);
            return JSONValue(o);
    }
}

/// A mutable deep copy of a `const` value: arrays and maps are rebuilt,
/// JSON is copied with `jsonCopy`, structs field by field. Data that is
/// already immutable (strings) is shared. This replaces `cast()` copies out
/// of `const`, which would let the copy write into the original.
U deepCopy(U)(const U v)
{
    import std.traits : hasIndirections, isAssociativeArray, KeyType, ValueType;
    import std.typecons : Nullable;
    static if (!hasIndirections!U) return v;
    else static if (is(U == JSONValue)) return jsonCopy(v);
    else static if (is(U == E[], E))
    {
        static if (is(E == immutable)) return v;
        else
        {
            U r;
            r.reserve(v.length);
            foreach (ref e; v) r ~= deepCopy!E(e);
            return r;
        }
    }
    else static if (isAssociativeArray!U)
    {
        U r;
        foreach (k, ref e; v) r[deepCopy!(KeyType!U)(k)] = deepCopy!(ValueType!U)(e);
        return r;
    }
    else static if (is(U == Nullable!X, X))
    {
        U r;
        if (!v.isNull) r = deepCopy!X(v.get);
        return r;
    }
    else static if (is(U == struct))
    {
        U r;
        static foreach (i; 0 .. U.tupleof.length)
            r.tupleof[i] = deepCopy!(typeof(U.tupleof[i]))(v.tupleof[i]);
        return r;
    }
    else static assert(0, "deepCopy: unsupported type " ~ U.stringof);
}

@safe unittest
{
    static struct In { int[] xs; string s; }
    static struct Out { In[] ins; string[string] m; int n; }
    const Out o = Out([In([1, 2], "a")], ["k": "v"], 3);
    auto c = deepCopy(o);
    c.ins[0].xs[0] = 9;
    assert(o.ins[0].xs[0] == 1 && c.m["k"] == "v" && c.n == 3 && c.ins[0].s == "a");
}

@safe unittest
{
    import std.json : parseJSON;
    auto src = parseJSON(`{"a":[1,2.5,"x",true,null,{"b":18446744073709551615}]}`);
    const c = src;
    auto d = jsonCopy(c);
    assert(d.toString == src.toString);
    d["a"][0] = 9;
    assert(src["a"][0].integer == 1);
}
