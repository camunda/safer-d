/// Threads that can only share what their types say they share (the
/// "E profile"): `spawn` takes a context-free function and sendable
/// arguments, threads talk through `Chan`s or `Locked`/`Shared` state, and
/// `Isolated` moves a uniquely owned value across. safer-d-check bans raw
/// threads, `std.concurrency`, `__gshared` and unions outside the io modules
/// (SD007, SD008) and caps `assumeIsolated` (SD009).
module safer.concurrency;

@safe:

// druntime's Condition and Thread methods carry no attributes, so they are
// @system; they only take the object's own lock and state.
import core.sync.condition : Condition;
import core.thread : Thread;

/// `t.isRunning`.
bool threadRunning(Thread t) @trusted { return t.isRunning; }

/// `c.notify()`.
void signalOne(Condition c) @trusted { c.notify(); }
/// `c.notifyAll()`.
void signalAll(Condition c) @trusted { c.notifyAll(); }
/// `c.wait()` (the caller holds `c`'s mutex).
void waitOn(Condition c) @trusted { c.wait(); }
/// `t.join()`; rethrows what the thread threw.
void joinThread(Thread t) @trusted { t.join(); }

/// A value shared between threads that is only reachable under its lock.
/// Declare it `shared` (`shared Locked!T x = new shared Locked!T;`): the
/// compiler then rejects any access that bypasses `get`/`update`. `T` may
/// not hold unshared mutable references, so neither a copy out of `get` nor
/// anything `update` stores can alias the locked value from another thread.
import std.traits : hasUnsharedAliasing;
final class Locked(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private T value;
    private Mutex mutex;
    private Condition changed;

    /// `@trusted`: casts away `shared` only on a freshly built object.
    this(T v = T.init) shared @trusted
    {
        auto self = cast() this;
        self.value = v;
        self.mutex = new Mutex;
        self.changed = new Condition(self.mutex);
    }

    /// A copy of the value.
    /// `@trusted`: the unshared view of `value` is used only under the lock.
    T get() shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        return self.value;
    }

    /// Run `f` on the value under the lock, and wake `await`ers. `f` is
    /// `scope`: it can't keep the reference.
    /// `@trusted`: as for `get`; the `ref` can't outlive `f` (DIP1000).
    R update(R = void)(scope R delegate(ref T) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }

    /// Block until `ready(value)` holds, then run `f` under the same lock.
    /// `@trusted`: as for `update`.
    R await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        while (!ready(self.value)) self.changed.wait();
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }
}

/// A copyable, sendable handle to a `shared Locked!T` (like Rust's
/// `Arc<Mutex<T>>`), so holders needn't spell `shared` or `atomicLoad`.
struct Shared(T)
{
    import core.atomic : atomicLoad;
    private shared Locked!T impl;
    /// A new cell holding `v`.
    static Shared make(T v = T.init) { return Shared(new shared Locked!T(v)); }
    /// Whether this handle refers to a cell.
    bool opCast(B : bool)() const { return atomicLoad(impl) !is null; }
    /// See `Locked`.
    T get() { return atomicLoad(impl).get(); }
    /// ditto
    R update(R = void)(scope R delegate(ref T) @safe f) { return atomicLoad(impl).update!R(f); }
    /// ditto
    R await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f)
    {
        return atomicLoad(impl).await!R(ready, f);
    }
}

@safe unittest
{
    static struct S { int n; string s; }
    shared Locked!S l = new shared Locked!S(S(1, "a"));
    l.update((ref S v) { v.n++; });
    assert(l.get == S(2, "a"));
    static assert(!__traits(compiles, new shared Locked!(int[])));
}

// ---- Sendable-only threads ----------------------------------------------
//
// The "E profile": threads start only through `spawn`, which takes a plain
// `function` (no hidden closure context) and arguments that are sendable,
// and threads talk through `Channel`s of sendable values or `Locked` state.
// safer-d-check bans `new Thread` outside the io modules (SD007), so data
// shared between threads is visible in the types.

/// Whether a value of type `T` may be handed to another thread: it holds no
/// unshared mutable references (immutable, `shared` or plain data, function
/// pointers), or it is an `Isolated` whose holder gives it up. Delegates are
/// not sendable: their context can reach anything.
enum bool isSendable(T) = !hasUnsharedAliasing!T || is(T : Isolated!U, U);

/// A value with exactly one owner: nothing outside it refers to it or to
/// anything it reaches, so it may move to another thread. It can't be
/// copied, only moved (`std.algorithm.move`) or taken with `unwrap`.
struct Isolated(T)
{
    private T payload;
    @disable this(this);

    /// Claim that nothing else refers to `value` (e.g. it was just built).
    /// The compiler can't check this; safer-d-check counts every call
    /// against the `isolation` budget (SD009), so each claim gets reviewed.
    static Isolated assumeIsolated(T value)
    {
        Isolated r;
        r.payload = value;
        return r;
    }

    /// Take the value out (the holder is left empty).
    T unwrap()
    {
        auto v = payload;
        payload = T.init;
        return v;
    }

    /// Make it immutable: sound because nothing else can still change it.
    /// `@trusted`: the cast is what isolation licenses (`assumeUnique`).
    immutable(T) freeze() @trusted
    {
        auto v = unwrap();
        return cast(immutable) v;
    }
}

/// A started thread, to wait for or poll; `join` returns what its function
/// returned (an `R`, which must be sendable).
struct Join(R)
{
    private Thread thread;
    static if (!is(R == void)) private ResultBox!R box;

    /// Wait for the thread to finish (rethrows what killed it).
    R join()
    {
        joinThread(thread);
        static if (!is(R == void)) return takeResult(box);
    }

    /// Whether the thread is still running.
    bool running() { return threadRunning(thread); }
}

/// A thread whose function returns nothing.
alias JoinHandle = Join!void;

private final class ResultBox(R) { Unqual!R value; }

/// `@trusted`: the thread wrote `box.value` before it ended, and `join`
/// waited for that (a happens-before edge), so nothing else touches it now.
private R takeResult(R)(ResultBox!R box) @trusted
{
    import core.lifetime : move;
    return cast(R) move(box.value);
}

/// Run `fn(args)` on a new thread. `fn` is a plain function, so it can only
/// reach what it is given (and `shared` or thread-local globals), and every
/// argument, and the result, must be sendable.
Join!R spawn(R, Args...)(R function(Args) @safe fn, auto ref Args args)
    if (allSatisfy!(isSendable, Args) && (is(R == void) || isSendable!R))
{
    return startSpawned(fn, args, false);
}

/// `spawn` for a daemon thread, which doesn't keep the process alive.
Join!R spawnDaemon(R, Args...)(R function(Args) @safe fn, auto ref Args args)
    if (allSatisfy!(isSendable, Args) && (is(R == void) || isSendable!R))
{
    return startSpawned(fn, args, true);
}

import std.meta : allSatisfy, staticMap;
import std.traits : Unqual;
// `= void`: an argument type may have no default (`@disable this()`, as
// NotNull does); each slot is filled by `moveEmplace` before any read.
private final class SpawnBox(Args...) { staticMap!(Unqual, Args) args = void; }

/// `@trusted`: the arguments (checked sendable by `spawn`) are moved into a
/// box only the new thread can reach; `shared` is stripped for the move and
/// restored for the call. `fn` is a context-free function. The result goes
/// into a box read only after `join`.
private Join!R startSpawned(R, Args...)(R function(Args) @safe fn, ref Args args, bool daemon) @trusted
{
    import core.lifetime : move, moveEmplace;
    auto box = new SpawnBox!Args;
    static foreach (i; 0 .. Args.length)
        moveEmplace(*cast(Unqual!(Args[i])*) &args[i], box.args[i]);
    Join!R h;
    static if (is(R == void))
        auto t = new Thread({ mixin("fn(" ~ callArgs!(Args.length) ~ ");"); });
    else
    {
        auto rb = h.box = new ResultBox!R;
        auto t = new Thread({ mixin("rb.value = cast(Unqual!R) fn(" ~ callArgs!(Args.length) ~ ");"); });
    }
    t.isDaemon = daemon;
    h.thread = t.start();
    return h;
}

private template callArgs(size_t n)
{
    import std.conv : to;
    enum callArgs = () {
        string r;
        foreach (i; 0 .. n) r ~= (i ? ", " : "") ~ "cast(Args[" ~ i.to!string ~ "]) move(box.args[" ~ i.to!string ~ "])";
        return r;
    }();
}

/// A handle to a `Channel`: copyable and sendable, so each thread holds its
/// own (like Rust's `Arc<Channel>`). `Chan!T.make` creates one.
struct Chan(T)
{
    import core.atomic : atomicLoad;
    private shared Channel!T impl;

    /// A new, open channel.
    static Chan make() { return Chan(new shared Channel!T); }
    /// Whether this handle refers to a channel.
    bool opCast(B : bool)() const { return atomicLoad(impl) !is null; }
    /// See `Channel`.
    void put(T v, bool front = false) { atomicLoad(impl).put(v, front); }
    /// ditto
    void close() { atomicLoad(impl).close(); }
    /// ditto
    bool take(out T v) { return atomicLoad(impl).take(v); }
    /// ditto
    bool tryTake(out T v) { return atomicLoad(impl).tryTake(v); }
    /// ditto
    void edit(scope void delegate(ref T[]) @safe f) { atomicLoad(impl).edit(f); }
}

/// A blocking queue of sendable values between threads, closable. Use it
/// through `Chan`.
final class Channel(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private Mutex lock;
    private Condition ready;
    private T[] items;
    private bool closed;

    /// `@trusted`: initialises the fresh object's own lock.
    this() shared @trusted
    {
        auto self = cast() this;
        self.lock = new Mutex;
        self.ready = new Condition(self.lock);
    }

    /// Append `v` (or put it first); wakes one taker.
    /// `@trusted`: the unshared view is used only while holding `lock`.
    void put(T v, bool front = false) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.items = front ? v ~ self.items : self.items ~ v;
        self.ready.notify();
    }

    /// No more values: takers drain what is left, then get false.
    /// `@trusted`: as for `put`.
    void close() shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.closed = true;
        self.ready.notifyAll();
    }

    /// Wait for the next value; false once closed and empty.
    /// `@trusted`: as for `put`.
    bool take(out T v) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        while (!self.items.length && !self.closed) self.ready.wait();
        if (!self.items.length) return false;
        v = self.items[0];
        self.items = self.items[1 .. $];
        return true;
    }

    /// The next value if one is waiting (doesn't block).
    /// `@trusted`: as for `put`.
    bool tryTake(out T v) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        if (!self.items.length) return false;
        v = self.items[0];
        self.items = self.items[1 .. $];
        return true;
    }

    /// Run `f` on the queued values under the lock (e.g. to reorder them).
    /// `@trusted`: as for `put`; `f` can't keep the reference (`scope`).
    void edit(scope void delegate(ref T[]) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        f(self.items);
    }
}

@safe unittest // spawn moves an Isolated, Channel carries results back
{
    static void worker(Isolated!(int[]) xs, Chan!int ch)
    {
        auto a = xs.unwrap;
        foreach (x; a) ch.put(x * 2);
        ch.close();
    }
    import core.lifetime : move;
    auto ch = Chan!int.make;
    auto xs = Isolated!(int[]).assumeIsolated([1, 2, 3]);
    auto h = spawn(&worker, move(xs), ch);
    int v, sum;
    while (ch.take(v)) sum += v;
    h.join();
    assert(sum == 12);
    static assert(isSendable!(immutable(int)[]) && isSendable!string && isSendable!(Chan!int));
    static assert(!isSendable!(int[]) && !isSendable!(void delegate()) && !isSendable!Object);
    static int add(int a, int b) { return a + b; }
    assert(spawn(&add, 2, 3).join() == 5);
    static void bad(int[] a) {}
    static assert(!__traits(compiles, spawn(&bad, [1])));
}
