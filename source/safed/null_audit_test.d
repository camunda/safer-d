/// Runs safed.nullaudit over safe-d's own modules: no field or global holds
/// a bare class reference. safe-d-check (SD018) fails when one is missing.
module safed.null_audit_test;

@safe:

import safed.nullaudit : auditModules;
static import safed;
static import safed.arith;
static import safed.concurrency;
static import safed.io;
static import safed.json;
static import safed.nullaudit;
static import safed.option;
static import safed.result;

unittest
{
    auto bare = auditModules!(safed.arith, safed.concurrency, safed.io, safed.json, safed.nullaudit,
        safed.option, safed.result)();
    assert(bare.length == 0, imported!"std.array".join(bare, "\n"));
}
