/// Runs safer.nullaudit over safer-d's own modules: no field or global holds
/// a bare class reference. safer-d-check (SD018) fails when one is missing.
module safer.null_audit_test;

@safe:

import safer.nullaudit : auditModules;
static import safer;
static import safer.arith;
static import safer.concurrency;
static import safer.io;
static import safer.json;
static import safer.nullaudit;
static import safer.option;
static import safer.result;

unittest
{
    auto bare = auditModules!(safer.arith, safer.concurrency, safer.io, safer.json, safer.nullaudit,
        safer.option, safer.result)();
    assert(bare.length == 0, imported!"std.array".join(bare, "\n"));
}
