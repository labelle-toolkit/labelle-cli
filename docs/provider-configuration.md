# Provider-owned project settings

Declare a JSON settings file for a package already listed in `.plugins`:

```zig
.provider_config = .{
    .{ .package = "labelle-example", .file = "providers/example.json" },
},
```

Each entry requires exactly `package` and `file`. Both the CLI and assembler
accept the same shape and reject unknown entry fields, duplicate package
mappings, invalid package identifiers and undeclared packages. Paths use
forward slashes, are project-relative, and cannot contain `..`, a drive prefix,
backslashes or empty components. Omitting the mapping gives `config_file: null`.

Before compiling or running a provider command, the CLI checks every mapping
against the resolved providers. A runtime-only plugin or an unverified remote
package cannot receive provider settings. Each file must exist, be a regular
file, resolve inside the canonical project root, and contain valid JSON within
the 1 MiB input limit. Symlinks/junctions within the project work; links outside
it fail. Malformed JSON and duplicate JSON keys fail before any provider build.
Diagnostics identify the package/path without dumping settings contents.

The selected provider receives the canonical absolute filename through
`LABELLE_CONTEXT`'s `config_file`. JSON content and semantic validation belong
to that provider. It must check required settings before producing side
effects. The CLI does not translate old platform-specific fields, invent
defaults, inject credentials or interpret platform settings.

Every invocation validates and reads the current file. Compiled host tools may
be reused, but command execution is never skipped on account of that cache.
The provider must include settings contents in any build/staging output cache
it owns; a cached executable is not a cached command result. Edits are visible
on the next invocation without changing the provider pin.

## Assembler requirement

Use a matching assembler build containing the shared `.provider_config` schema
and plugin manifest-v2 support. Older assembler releases reject this new field;
adopt the paired assembler change before migrating projects or publishing the
CLI release. No release version is invented or automatically substituted.

Plugin v2 extends the v1 runtime declaration shape with CLI-owned command/hook
metadata. The assembler preserves runtime declarations but does not execute
commands or hooks. Pack manifests retain their independent v1 version gate.
The assembler parses the settings mapping even on the plugin-params extraction
path, without embedding settings contents into generated game code.

## Verification

`zig build test-provider-dispatch` covers the CLI parser. The assembler's
`zig build test-provider-config` exercises the real project parser plus plugin
and pack loaders; these tests also run in the normal test target.

After `zig build`, run `python test/provider_config_e2e.py --zig /path/to/zig`.
It exercises real subprocesses, edits, canonical paths, null defaults, invalid
mappings/files/JSON, provider-owned schema validation and internal/external
links. Rejected configuration is tested with a deliberately broken build script
to prove validation runs before building. The GitHub provider suite also checks
project-owned settings with a verified remote provider.
