/// Runs safed.nullaudit over every module but app (which audits itself):
/// a field or global holding a bare class reference must become
/// `NotNull!C`, `Option!C` or `@nullable("why") C`. safe-d-check (SD018)
/// fails when a module is missing from this list.
module {{module}}.null_audit_test;

@safe:

import safed.nullaudit : auditModules;
static import {{module}}.greet;

unittest
{
    auto bare = auditModules!({{module}}.greet)();
    assert(bare.length == 0, "bare class references (use NotNull!C, Option!C or @nullable(\"why\")):\n  "
        ~ imported!"std.array".join(bare, "\n  "));
}
