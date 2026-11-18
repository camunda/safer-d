/// @safe views of Phobos calls that are not marked @safe: the standard
/// streams and whole-file reads. Each is `@trusted` on its own, with the
/// reason it is memory safe beside it, so code using them stays `@safe:`.
///
/// Project-specific escapes (POSIX fds, terminals, signals) belong in the
/// project's own io module, which its safe-d.json lists under `ioModules`.
module safed.io;

@safe:

import std.stdio : File;

/// `std.stdio.stdout`. Phobos marks it @system only because the `File` is a
/// `__gshared` global; every `File` operation locks the stream itself.
@property ref File stdOut() @trusted
{
    import std.stdio : stdout;
    return stdout;
}

/// `std.stdio.stderr`; see `stdOut`.
@property ref File stdErr() @trusted
{
    import std.stdio : stderr;
    return stderr;
}

/// `std.file.read` as bytes. The `void[]` it returns is freshly allocated
/// and untyped, so viewing it as `ubyte[]` aliases nothing else.
ubyte[] readBytes(string path) @trusted
{
    import std.file : read;
    return cast(ubyte[]) read(path);
}

/// A file's bytes, reading at most `cap + 1`; null when it holds more than
/// `cap` (checked while reading, so a growing file can't slip past).
ubyte[] readCapped(string path, ulong cap) @safe
{
    import std.algorithm : min;
    import std.stdio : File;
    auto f = File(path, "rb");
    auto size = f.size; // a hint only: the file may grow while read
    auto buf = new ubyte[cast(size_t) min(cap + 1, size == ulong.max ? 64 * 1024 : size + 1)];
    size_t got;
    for (;;)
    {
        if (got == buf.length)
        {
            if (buf.length > cap) break;
            buf.length = cast(size_t) min(buf.length * 2, cap + 1);
        }
        auto r = f.rawRead(buf[got .. $]);
        if (!r.length) break;
        got += r.length;
    }
    if (got > cap) return null;
    return got ? buf[0 .. got] : [];
}

/// `std.file.read` as immutable bytes: the buffer is freshly allocated and
/// only this result refers to it.
immutable(ubyte)[] readImmutableBytes(string path) @trusted
{
    import std.file : read;
    return cast(immutable(ubyte)[]) read(path);
}

/// `std.file.read` as (possibly invalid) UTF-8 text, without validating it.
string readRawText(string path) @trusted
{
    import std.file : read;
    return cast(string) read(path);
}

/// A byte buffer nothing else references, viewed as (possibly invalid) UTF-8
/// text. The caller must hand over the only reference: the bytes become
/// immutable, so a later write through another alias would break that.
string ownText(ubyte[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

/// `ownText` for a `char[]` buffer.
string ownText(char[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

import std.file : DirEntry, SpanMode;
/// `std.file.dirEntries` collected into an array. Phobos marks the iterator
/// @system only for its reference-counted handle; the entries themselves are
/// plain values. Throws `FileException` as `dirEntries` does.
DirEntry[] listDir(string dir, SpanMode mode, bool followSymlink = false) @trusted
{
    import std.file : dirEntries;
    DirEntry[] r;
    foreach (DirEntry e; dirEntries(dir, mode, followSymlink)) r ~= e;
    return r;
}

@safe unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "safe-d-io-test");
    write(p, "hi");
    scope (exit) remove(p);
    assert(readBytes(p) == cast(const(ubyte)[]) "hi");
    assert(ownText(readBytes(p)) == "hi");
    assert(readRawText(p) == "hi" && readImmutableBytes(p) == cast(immutable(ubyte)[]) "hi");
    assert(readCapped(p, 2) == cast(const(ubyte)[]) "hi" && readCapped(p, 1) is null);
    import std.algorithm : canFind, map;
    assert(listDir(tempDir, SpanMode.shallow).map!(e => e.name).canFind(p));
    assert(stdOut.isOpen && stdErr.isOpen);
}
