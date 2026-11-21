/// {{name}}: entry point. Every module starts with `@safe:` (SD001); the
/// escapes the compiler can't check live in safer-d's own modules.
module app;

@safe:

import safer.io : stdOut;
import {{module}}.greet : greeting;

int main(string[] args)
{
    stdOut.writeln(greeting(args.length > 1 ? args[1] : "world"));
    return 0;
}

// `dub test` leaves the main module out, so it audits itself: no field or
// global may hold a bare class reference (use NotNull!C or Option!C).
static assert(imported!"safer.nullaudit".bareRefs!(app)().length == 0);
