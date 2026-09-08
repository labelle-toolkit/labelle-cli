# Declaring plugin core compatibility

A plugin may declare the core versions it supports in `plugin.labelle`:

```zig
.{
    .name = "pathfinder",
    .manifest_version = 1,
    .core_compat = ">=1.20.0 <2.0.0",
}
```

The CLI checks this declaration after dependency installation and before generation. A mismatch or malformed declaration prints a warning and the build continues. A missing manifest or declaration leaves compatibility unchecked. Local core overrides have no comparable version and are skipped.

Ranges are conjunctions of up to four comparisons separated by spaces, tabs or commas. Operators are `>=`, `>`, `<=`, `<`, `=` and `==`; a bare version means exact equality. Use full `MAJOR.MINOR.PATCH` versions. Prereleases follow semantic-version precedence and build metadata does not affect ordering. Wildcards, caret ranges and alternatives are not supported and receive a malformed-range warning.

Run unit tests with `zig build test`. On a POSIX host with Python 3, run `zig build && python3 test/plugin_compat_e2e.py` for the offline pipeline regression. It creates a remote manifest during a fake assembler's install phase, exercises the real CLI, and checks warnings arrive before generation. CI runs it on Linux and macOS.
