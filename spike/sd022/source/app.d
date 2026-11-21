/// Spike: a type-aware safe-d rule on the dmd frontend (2.113 == LDC 1.43).
///
/// SD022 (proposed): a local class reference is dereferenced where it is null
/// or may be null. Flow-sensitive over the semantic AST: tracks each local
/// class variable as Null / NonNull / Maybe through assignments, branches,
/// loops, null checks (`is null`, `!is null`, `if (c)`, `&&`, `||`, `assert`)
/// and early exits (return, throw, assert(0), break, continue).
///
/// Values from calls, fields and parameters are not tracked (assumed set):
/// the rule finds the null a function makes for itself, not every reference
/// that could be null. That is Kotlin's "platform type" trade.
module app;

import core.stdc.stdarg : va_list;
import core.stdc.stdio : vsnprintf;
import std.stdio : writeln, writefln, stderr;
import std.file : readText;
import std.string : fromStringz;
import std.datetime.stopwatch : StopWatch, AutoStart;

import dmd.frontend;
import dmd.astenums : Ty = TY, STMT;
import dmd.dsymbol : Dsymbol;
import dmd.arraytypes : Dsymbols;
import dmd.dsymbolsem : include;
import dmd.func : FuncDeclaration;
import dmd.declaration : VarDeclaration;
import dmd.statement;
import dmd.expression;
import dmd.tokens : EXP;
import dmd.location : SourceLoc;
import dmd.console : Color;
import dmd.errors : DiagnosticHandler;
import dmd.globals : global, FeatureState;

enum S : ubyte { unknown, nonNull, isNull, maybe }

struct Flow
{
    S[size_t] st;     // VarDeclaration identity -> state; absent = unknown (assumed set)
    bool live = true; // reachable
}

S get(ref Flow f, size_t k) { if (auto p = k in f.st) return *p; return S.unknown; }

S joinS(S a, S b)
{
    if (a == b) return a;
    if (a == S.maybe || b == S.maybe) return S.maybe;
    if (a == S.isNull || b == S.isNull) return S.maybe; // null with anything else
    return S.unknown;                                    // nonNull with unknown
}

Flow copy(Flow f) { Flow r; r.st = f.st.dup; r.live = f.live; return r; }
Flow dead() { Flow r; r.live = false; return r; }
bool same(Flow a, Flow b) { return a.live == b.live && a.st == b.st; }

Flow join(Flow a, Flow b)
{
    if (!a.live) return b.copy;
    if (!b.live) return a.copy;
    Flow r;
    foreach (k, v; a.st) r.st[k] = joinS(v, get(b, k));
    foreach (k, v; b.st) if (k !in r.st) r.st[k] = joinS(S.unknown, v);
    return r;
}

/// `=`, and the construct/blit forms semantic uses for initialisers.
AssignExp asAssign(Expression e)
{
    if (e is null) return null;
    if (e.op == EXP.assign || e.op == EXP.construct || e.op == EXP.blit) return cast(AssignExp) e;
    return null;
}

size_t key(VarDeclaration v) { return cast(size_t) cast(void*) v; }

/// A local (or parameter) whose type is a class reference.
VarDeclaration tracked(Expression e)
{
    if (e is null) return null;
    auto ve = e.isVarExp();
    if (ve is null) return null;
    auto v = ve.var.isVarDeclaration();
    if (v is null || v.type is null || v.type.ty != Ty.Tclass) return null;
    if (v.isDataseg() || v.isField() || v.isRef()) return null;
    return v;
}

struct Finding { string loc; string msg; }

struct Ctx { Flow[] breaks; Flow[] conts; }

final class Analyzer
{
    Finding[] findings;
    Ctx[] loops;
    size_t nFuncs, nLocals, nDerefs, nChecks;
    bool[size_t] seen;

    // ---- expressions -------------------------------------------------

    S valueOf(Expression e, ref Flow f)
    {
        if (e is null) return S.unknown;
        if (e.isNullExp()) return S.isNull;
        if (e.isNewExp() || e.isThisExp()) return S.nonNull;
        if (auto v = tracked(e)) return get(f, key(v));
        if (auto c = e.isCastExp()) return valueOf(c.e1, f);
        if (auto c = e.isCommaExp()) return valueOf(c.e2, f);
        if (auto c = e.isCondExp())
        {
            auto t = f.copy, g = f.copy;
            return joinS(valueOf(c.e1, t), valueOf(c.e2, g));
        }
        return S.unknown;
    }

    void deref(Expression base, Expression at, ref Flow f)
    {
        auto v = tracked(base);
        if (v is null || !f.live) return;
        nDerefs++;
        const s = get(f, key(v));
        if (s == S.isNull || s == S.maybe)
        {
            const where = at.loc.toChars().fromStringz.idup;
            foreach (x; findings) if (x.loc == where) { f.st[key(v)] = S.nonNull; return; }
            findings ~= Finding(at.loc.toChars().fromStringz.idup,
                "SD022 `" ~ v.ident.toString().idup ~ "` " ~
                (s == S.isNull ? "is null here" : "may be null here") ~
                "; check it, or make it an `Option`/`NotNull`");
            f.st[key(v)] = S.nonNull; // report once per path
        }
    }

    /// Evaluates `e` for its effects and dereferences.
    void exp(Expression e, ref Flow f)
    {
        if (e is null || !f.live) return;
        if (e.isLogicalExp()) { auto tf = cond(e, f); f = join(tf[0], tf[1]); return; }
        if (auto c = e.isCondExp())
        {
            auto tf = cond(c.econd, f);
            exp(c.e1, tf[0]);
            exp(c.e2, tf[1]);
            f = join(tf[0], tf[1]);
            return;
        }
        if (auto a = asAssign(e)) // also Construct/Blit
        {
            exp(a.e2, f);
            if (auto v = tracked(a.e1)) { f.st[key(v)] = valueOf(a.e2, f); return; }
            exp(a.e1, f);
            return;
        }
        if (auto d = e.isDeclarationExp())
        {
            if (auto v = d.declaration.isVarDeclaration())
            {
                auto ei = v._init ? v._init.isExpInitializer() : null;
                if (ei) exp(ei.exp, f);
                const local = v.type && v.type.ty == Ty.Tclass && !v.isDataseg() && !v.isRef();
                if (local)
                {
                    nLocals++;
                    Expression init = ei ? ei.exp : null;
                    if (auto ae = asAssign(init)) init = ae.e2; // Construct/Blit
                    f.st[key(v)] = init is null ? S.isNull : valueOf(init, f);
                }
            }
            else if (auto fd = d.declaration.isFuncDeclaration())
                analyzeFunc(fd);
            return;
        }
        if (auto fe = e.isFuncExp()) { if (fe.fd) analyzeFunc(fe.fd); return; }
        if (auto dv = e.isDotVarExp()) { exp(dv.e1, f); deref(dv.e1, e, f); return; }
        if (auto a = e.isAssertExp())
        {
            auto tf = cond(a.e1, f);
            f = tf[0];
            if (a.e1.isIntegerExp() && a.e1.isIntegerExp().getInteger() == 0) f = dead();
            return;
        }
        if (auto t = e.isThrowExp()) { exp(t.e1, f); f = dead(); return; }
        if (auto c = e.isCallExp())
        {
            exp(c.e1, f);
            if (c.arguments) foreach (arg; *c.arguments) exp(arg, f);
            if (c.type && c.type.ty == Ty.Tnoreturn) f = dead(); // die(), exit paths
            return;
        }
        if (auto n = e.isNewExp())
        {
            if (n.thisexp) exp(n.thisexp, f);
            if (n.arguments) foreach (arg; *n.arguments) exp(arg, f);
            return;
        }
        if (auto al = e.isArrayLiteralExp()) { if (al.elements) foreach (x; *al.elements) exp(x, f); return; }
        if (auto sl = e.isStructLiteralExp()) { if (sl.elements) foreach (x; *sl.elements) exp(x, f); return; }
        if (auto b = e.isBinExp()) { exp(b.e1, f); exp(b.e2, f); return; }
        if (auto u = e.isUnaExp()) { exp(u.e1, f); return; }
    }

    /// Evaluates a condition: the flows where it is true and where it is false.
    Flow[2] cond(Expression e, ref Flow f)
    {
        if (e is null || !f.live) return [f.copy, f.copy];
        if (auto n = e.isNotExp()) { auto tf = cond(n.e1, f); return [tf[1], tf[0]]; }
        if (auto c = e.isCastExp())
            if (c.to && c.to.ty == Ty.Tbool) return cond(c.e1, f);
        if (auto l = e.isLogicalExp())
        {
            auto a = cond(l.e1, f);
            if (l.op == EXP.andAnd)
            {
                auto b = cond(l.e2, a[0]);
                return [b[0], join(a[1], b[1])];
            }
            auto b = cond(l.e2, a[1]);
            return [join(a[0], b[0]), b[1]];
        }
        if (auto v = tracked(e)) // if (c)
        {
            auto t = f.copy, g = f.copy;
            t.st[key(v)] = S.nonNull;
            g.st[key(v)] = S.isNull;
            return [t, g];
        }
        VarDeclaration v;
        bool eqNull; // condition true means v is null
        if (auto id = e.isIdentityExp())
        {
            if (id.e2.isNullExp()) v = tracked(id.e1);
            else if (id.e1.isNullExp()) v = tracked(id.e2);
            eqNull = id.op == EXP.identity;
        }
        else if (auto eq = e.isEqualExp())
        {
            if (eq.e2.isNullExp()) v = tracked(eq.e1);
            else if (eq.e1.isNullExp()) v = tracked(eq.e2);
            eqNull = eq.op == EXP.equal;
        }
        if (v !is null)
        {
            nChecks++;
            auto t = f.copy, g = f.copy;
            t.st[key(v)] = eqNull ? S.isNull : S.nonNull;
            g.st[key(v)] = eqNull ? S.nonNull : S.isNull;
            return [t, g];
        }
        exp(e, f);
        return [f.copy, f.copy];
    }

    // ---- statements --------------------------------------------------

    Flow joinAll(Flow[] fs) { Flow r = dead(); foreach (x; fs) r = join(r, x); return r; }

    Flow stmt(Statement s, Flow f)
    {
        if (s is null || !f.live) return f;
        import std.process : environment;
        if (environment.get("SDDEBUG")) { import std.stdio : writefln; writefln("stmt %s %s", s.stmt, s.loc.toChars().fromStringz); if (auto es = s.isExpStatement()) if (es.exp) writefln("   exp op=%s %s", es.exp.op, es.exp.toChars().fromStringz); }
        switch (s.stmt)
        {
            case STMT.Exp, STMT.DtorExp:
                exp((cast(ExpStatement) s).exp, f);
                return f;
            case STMT.Compound, STMT.CompoundDeclaration, STMT.CompoundAsm:
                auto cs = cast(CompoundStatement) s;
                if (cs.statements) foreach (x; *cs.statements) f = stmt(x, f);
                return f;
            case STMT.UnrolledLoop:
                auto ul = s.isUnrolledLoopStatement();
                loops ~= Ctx();
                if (ul.statements) foreach (x; *ul.statements)
                {
                    auto o = stmt(x, f);
                    f = join(o, joinAll(loops[$-1].conts));
                    loops[$-1].conts = null;
                }
                auto uc = loops[$-1]; loops = loops[0 .. $-1];
                return join(f, joinAll(uc.breaks));
            case STMT.Scope:
                return stmt(s.isScopeStatement().statement, f);
            case STMT.Forwarding:
                return stmt(s.isForwardingStatement().statement, f);
            case STMT.Label:
                return stmt(s.isLabelStatement().statement, f);
            case STMT.Debug:
                return stmt(s.isDebugStatement().statement, f);
            case STMT.Peel:
                return stmt(s.isPeelStatement().s, f);
            case STMT.If:
                auto ifs = s.isIfStatement();
                auto tf = cond(ifs.condition, f);
                auto a = stmt(ifs.ifbody, tf[0]);
                auto b = ifs.elsebody ? stmt(ifs.elsebody, tf[1]) : tf[1];
                return join(a, b);
            case STMT.Return:
                exp(s.isReturnStatement().exp, f);
                return dead();
            case STMT.Throw:
                exp(s.isThrowStatement().exp, f);
                return dead();
            case STMT.Break:
                if (loops.length) loops[$-1].breaks ~= f;
                return dead();
            case STMT.Continue:
                if (loops.length) loops[$-1].conts ~= f;
                return dead();
            case STMT.Goto, STMT.GotoCase, STMT.GotoDefault, STMT.SwitchError:
                return dead();
            case STMT.For:
                auto fs = s.isForStatement();
                f = stmt(fs._init, f);
                return loop(f, fs.condition, fs._body, fs.increment, false);
            case STMT.While:
                auto ws = s.isWhileStatement();
                return loop(f, ws.condition, ws._body, null, false);
            case STMT.Do:
                auto ds = s.isDoStatement();
                return loop(f, ds.condition, ds._body, null, true);
            case STMT.Foreach:
                auto fe = s.isForeachStatement();
                exp(fe.aggr, f);
                return loop(f, null, fe._body, null, false, true);
            case STMT.ForeachRange:
                auto fr = s.isForeachRangeStatement();
                exp(fr.lwr, f);
                exp(fr.upr, f);
                return loop(f, null, fr._body, null, false, true);
            case STMT.Switch:
                auto sw = s.isSwitchStatement();
                exp(sw.condition, f);
                loops ~= Ctx();
                auto entry = f.copy;
                auto o = switchBody(sw._body, entry);
                auto sc = loops[$-1]; loops = loops[0 .. $-1];
                auto r = join(o, joinAll(sc.breaks));
                if (!sw.sdefault) r = join(r, entry);
                return r;
            case STMT.TryCatch:
                auto tc = s.isTryCatchStatement();
                auto bodyOut = stmt(tc._body, f.copy);
                auto r = bodyOut;
                if (tc.catches) foreach (c; *tc.catches) r = join(r, stmt(c.handler, join(f, bodyOut)));
                return r;
            case STMT.TryFinally:
                auto tfs = s.isTryFinallyStatement();
                auto b = stmt(tfs._body, f.copy);
                stmt(tfs.finalbody, join(f, b)); // findings on every path into finally
                return b.live ? stmt(tfs.finalbody, b) : dead();
            case STMT.ScopeGuard:
                stmt(s.isScopeGuardStatement().statement, f.copy);
                return f;
            case STMT.Synchronized:
                return stmt(s.isSynchronizedStatement()._body, f);
            case STMT.With:
                auto w = s.isWithStatement();
                exp(w.exp, f);
                return stmt(w._body, f);
            case STMT.Case:
                return stmt(s.isCaseStatement().statement, f);
            case STMT.Default:
                return stmt(s.isDefaultStatement().statement, f);
            default:
                return f;
        }
    }

    /// A switch body: each case starts from the entry state joined with
    /// fall-through.
    Flow switchBody(Statement s, Flow entry)
    {
        if (s is null) return entry;
        if (auto sc = s.isScopeStatement()) return switchBody(sc.statement, entry);
        auto cs = s.isCompoundStatement();
        if (cs is null) return stmt(s, entry);
        Flow f = entry.copy;
        if (cs.statements) foreach (x; *cs.statements)
        {
            if (x && (x.isCaseStatement() || x.isDefaultStatement() || x.isCaseRangeStatement()))
                f = join(f, entry);
            f = stmt(x, f);
        }
        return f;
    }

    Flow loop(Flow entry, Expression c, Statement body_, Expression incr, bool doWhile, bool zeroOrMore = false)
    {
        Flow head = entry.copy;
        Flow exit = dead();
        foreach (iter; 0 .. 4)
        {
            loops ~= Ctx();
            Flow inBody;
            Flow notTaken = dead();
            if (doWhile) inBody = head.copy;
            else if (c) { auto tf = cond(c, head); inBody = tf[0]; notTaken = tf[1]; }
            else { inBody = head.copy; notTaken = zeroOrMore ? head.copy : dead(); }
            auto o = stmt(body_, inBody);
            auto ctx = loops[$-1]; loops = loops[0 .. $-1];
            o = join(o, joinAll(ctx.conts));
            if (incr) exp(incr, o);
            if (doWhile && c) { auto tf = cond(c, o); o = tf[0]; notTaken = join(notTaken, tf[1]); }
            exit = join(notTaken, joinAll(ctx.breaks));
            auto next = join(entry, o);
            if (same(next, head)) break;
            head = next;
        }
        return exit;
    }

    // ---- declarations ------------------------------------------------

    void analyzeFunc(FuncDeclaration fd)
    {
        if (fd is null || fd.fbody is null) return;
        const k = cast(size_t) cast(void*) fd;
        if (k in seen) return;
        seen[k] = true;
        nFuncs++;
        auto saved = loops;
        loops = null;
        Flow f;
        stmt(fd.fbody, f);
        loops = saved;
    }

    void walk(Dsymbols* members)
    {
        if (members is null) return;
        foreach (d; *members) walkOne(d);
    }

    void walkOne(Dsymbol d)
    {
        if (d is null) return;
        if (auto fd = d.isFuncDeclaration()) { analyzeFunc(fd); return; }
        if (auto ad = d.isAttribDeclaration()) { walk(ad.include(null)); return; }
        if (d.isTemplateInstance() || d.isTemplateDeclaration()) return;
        if (auto ag = d.isAggregateDeclaration()) { walk(ag.members); return; }
        if (auto sd = d.isScopeDsymbol()) { walk(sd.members); return; }
    }
}

/// initDMD from dmd.frontend, but for the host target (AArch64 on Apple
/// silicon): LDC's druntime headers check struct sizes per architecture.
void initFrontend(DiagnosticHandler h)
{
    import dmd.cond : VersionCondition;
    import dmd.target : target;
    import dmd.identifier : Identifier;

    initDMD(h);
    version (AArch64)
    {
        // initDMD assumes x86_64 on 64-bit hosts; LDC's druntime headers
        // check struct sizes per architecture.
        target.isX86_64 = false;
        target.isAArch64 = true;
        target._init(global.params);
        Identifier[] keep;
        foreach (i; 0 .. global.versionids.length) keep ~= global.versionids[i];
        global.versionids.setDim(0);
        foreach (id; keep)
        {
            const n = id.toString();
            if (n == "X86_64" || n == "D_InlineAsm_X86_64" || n == "D_SIMD" || n == "D_AVX" || n == "D_AVX2")
                continue;
            global.versionids.push(id);
        }
        VersionCondition.addPredefinedGlobalIdent("AArch64");
    }
    foreach (id; ["LDC", "LDC_LLVM_23"]) VersionCondition.addPredefinedGlobalIdent(id.ptr);
}

int main(string[] args)
{
    // usage: sdspike <file.d>... -- <import paths>...
    string[] files, imports;
    bool sep;
    foreach (a; args[1 .. $])
    {
        if (a == "--") { sep = true; continue; }
        if (sep) imports ~= a; else files ~= a;
    }

    auto sw = StopWatch(AutoStart.yes);
    if (files.length > 1)
    {
        // deinitializeDMD doesn't reset everything (types survive), so each
        // file gets a fresh process.
        import std.process : execute;
        import std.string : lineSplitter, startsWith, indexOf;
        import std.conv : to;
        size_t findings, diags, failed;
        size_t[4] tot;
        foreach (file; files)
        {
            auto r = execute([args[0], file, "--"] ~ imports);
            foreach (line; r.output.lineSplitter)
            {
                if (line.indexOf(": Error: SD022") >= 0) { writeln(line); findings++; }
                else if (line.startsWith("sdspike: ")) {}
                else if (line.startsWith("stats: "))
                {
                    import std.array : split;
                    foreach (i, w; line["stats: ".length .. $].split) tot[i] += w.to!size_t;
                }
                else if (line.startsWith("  (compile)")) diags++;
            }
            if (r.status != 0 && r.status != 1) { failed++; stderr.writeln("  crashed: ", file); }
        }
        stderr.writefln("sdspike: %d file(s), %d finding(s), %d with compile diagnostics, %d crashed, %s",
            files.length, findings, diags, failed, sw.peek);
        stderr.writefln("coverage: %d functions, %d class-typed locals tracked, %d derefs of tracked locals checked, %d null checks used",
            tot[0], tot[1], tot[2], tot[3]);
        return findings ? 1 : 0;
    }

    size_t compileErrors;
    Finding[] all;
    foreach (file; files)
    {
        initFrontend(delegate bool(ref const SourceLoc, Color, const(char)*, const(char)* fmt, va_list ap, const(char)*, const(char)*) nothrow {
            compileErrors++;
            if (compileErrors <= 5)
            {
                import core.stdc.stdio : fprintf, vfprintf, cstderr = stderr;
                fprintf(cstderr, "  (compile) ");
                vfprintf(cstderr, fmt, ap);
                fprintf(cstderr, "\n");
            }
            return true;
        });
        global.params.useDIP1000 = FeatureState.enabled;
        foreach (p; imports) addImport(p);
        auto t = parseModule(file, readText(file));
        t.module_.fullSemantic();
        auto an = new Analyzer;
        an.walk(t.module_.members);
        foreach (fi; an.findings) all ~= fi;
        writefln("stats: %d %d %d %d", an.nFuncs, an.nLocals, an.nDerefs, an.nChecks);
        deinitializeDMD();
    }
    foreach (fi; all) writefln("%s: Error: %s", fi.loc, fi.msg);
    stderr.writefln("sdspike: %d file(s), %d finding(s), %d compile diagnostics, %s",
        files.length, all.length, compileErrors, sw.peek);
    return all.length ? 1 : 0;
}
