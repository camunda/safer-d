# Spike: SD022, flow-sensitive null on class references

Throwaway spike for a type-aware safe-d-check rule. It is not wired into
`safe-d:check`, and this code is not meant to be merged. The write-up is in
the linked issue.

It links the dmd front end (dmd 2.113.0 on code.dlang.org, the same front end
as LDC 1.43) as a library, without the backend. For each file it runs full
semantic analysis, then walks each function body. It tracks every class-typed
local as null, non-null or maybe-null across assignments, branches, loops,
`switch`, null checks (`is null`, `!is null`, `if (c)`, `!c`, `&&`, `||`,
`assert`) and paths that end (`return`, `throw`, `break`, `continue`, and
calls to `noreturn` functions such as `die()`). It reports any dereference
where the variable is null or may be null.

```sh
dub fetch dmd@2.113.0
ln -s ~/.dub/packages/dmd/2.113.0/dmd dmdpkg
dub build -b release
./sdspike fixtures.d -- /opt/homebrew/Cellar/ldc/1.43.0/include/dlang/ldc
./sdspike $(find ../project/source -name '*.d') -- <ldc include> ../project/source
```

`fixtures.d` seeds 7 bugs that must be reported, and 16 safe patterns that
must stay quiet.
