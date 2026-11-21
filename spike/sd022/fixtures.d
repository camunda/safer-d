module fixtures;
@safe:

class C { int x; int get() const { return x; } }
C make();

// ---- must report -------------------------------------------------------

int definitelyNull()
{
    C c = null;
    return c.x;                         // HIT: is null
}

int defaultInit()
{
    C c;
    return c.get();                     // HIT: is null
}

int oneBranch(bool b)
{
    C c;
    if (b) c = new C;
    return c.x;                         // HIT: may be null
}

int afterNullCheckWrongWay(C p)
{
    C c = p;
    if (c is null) { c.x = 1; }         // HIT: is null (inside the null branch)
    return 0;
}

int loopMaybe(int[] xs)
{
    C c;
    foreach (x; xs) c = new C;
    return c.x;                         // HIT: may be null (zero iterations)
}

int reassignedNull(bool b)
{
    C c = new C;
    if (b) c = null;
    return c.x;                         // HIT: may be null
}

int orBranch(C p, bool b)
{
    C c = b ? p : null;
    return c.x;                         // HIT: may be null
}

// ---- must stay quiet ---------------------------------------------------

int fromCall() { C c = make(); return c.x; }          // untracked source
int param(C p) { return p.x; }                         // untracked
int guarded(bool b) { C c; if (b) c = new C; if (c !is null) return c.x; return 0; }
int guardedAnd(bool b) { C c; if (b) c = new C; return c !is null && c.x > 0 ? 1 : 0; }
int guardedOr(bool b) { C c; if (b) c = new C; if (c is null || c.x == 0) return 0; return c.x; }
int earlyReturn(bool b) { C c; if (b) c = new C; if (c is null) return 0; return c.x; }
int earlyThrow(bool b) { C c; if (b) c = new C; if (!c) throw new Exception("x"); return c.x; }
int asserted(bool b) { C c; if (b) c = new C; assert(c !is null); return c.x; }
int bothBranches(bool b) { C c; if (b) c = new C; else c = new C; return c.x; }
int implicitBool(bool b) { C c; if (b) c = new C; if (c) return c.x; return 0; }
int loopFind(C[] xs)
{
    C found;
    foreach (x; xs) if (x.x == 1) { found = x; break; }
    if (found is null) return -1;
    return found.x;
}
int switchAll(int k)
{
    C c;
    switch (k)
    {
        case 1: c = new C; break;
        default: c = new C; break;
    }
    return c.x;
}
int whileSet() { C c; while (c is null) c = new C; return c.x; }
int lambda(bool b) { C c; if (b) c = new C; auto f = () => 1; return f(); }
noreturn die(string m);
int dieInCatch(bool b)
{
    C c;
    try c = make();
    catch (Exception e) die(e.msg);
    return c.x;
}
int dieOnNull(bool b) { C c; if (b) c = new C; if (c is null) die("no c"); return c.x; }
