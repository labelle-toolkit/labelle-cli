# Provider lifecycle hooks — phase 3a

This documents the hook-execution slice of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md) §6 and on
[project-local dispatch](provider-local-dispatch.md). A pinned provider can
now attach to the project's `generate`, `build`, `bundle` and `run` steps.
Provider-declared targets and `--platform` resolution are the next slice; the
platform packages themselves still remain to be extracted.

## Attaching

A hook record in `plugin.labelle` names one `(step, target)` and one phase:

```zig
.hooks = .{
    .{ .id = "sign", .step = .bundle, .target = "desktop", .when = .after,
       .build_step = "hook-sign", .executable = "bin/sign",
       .after_hooks = .{ "labelle-example/stamp" } },
},
```

- `step` is `generate`, `build`, `bundle` or `run`; `when` is `before`,
  `replace` or `after`. `build_step`/`executable` follow the installed-tool
  convention of the contract (§1) exactly as commands do.
- `before` and `after` hooks attach to any target, including core-owned
  `desktop`. A `replace` hook is accepted only for a target the same package
  declares in `.targets` (`ReplaceRequiresOwnedTarget`); since no package may
  own `desktop`, the core desktop steps can never be replaced.
- `after_hooks` entries are fully qualified `<package>/<id>` references
  (`InvalidHookReference` otherwise, including a reference to the hook
  itself).

Hooks require a project. Like commands, they run only for a provider whose
`labelle.lock` entry matches the declaration and — for a remote package —
whose integrity pin is accepted (`MissingProviderPin`, `StaleProviderPin`,
`RemoteProviderIntegrityRequired`). `provider_config` settings are resolved
the same way and passed as `config_file`.

## Discovery and the graph

Every project command that runs the pipeline (`generate`, `build`, `run`,
`bundle`, and the legacy platform commands that share its generation)
discovers the declared providers whenever `.plugins` is non-empty. Discovery
runs **after the package cache is populated** (the assembler's `install`) and
**before generation or any compiler**: a declared remote package that is
neither pinned nor yet in the ordinary cache has no manifest to read, so
discovering ahead of the installer took every such package for runtime-only
and a cold cache silently built without its hooks while a warm cache ran
them. With the cache populated, a non-local package that is still absent
from both caches fails discovery closed (`ProviderPackageMissing`); a package
directory without a `plugin.labelle` is a runtime-only package (light packs
ship no manifest). The whole hook graph is validated once, at discovery, so
`labelle help` and `labelle providers resolve --accept` (which validates the
accepted remote and local manifests together before writing
`labelle.providers.lock`) fail on the same problems a build would:

| Error | Rule |
| --- | --- |
| `DuplicateReplaceHook` | two `replace` hooks for one `(step, target)` |
| `MissingHookReference` | an `after_hooks` entry names no hook |
| `HookReferenceMismatch` | it names a hook on another `(step, target)` |
| `HookPhaseOrder` | it names a hook in a later phase (`before` → `replace`/`after`, `replace` → `after`) |
| `HookCycle` | a cycle among same-phase references |

Each prints one `labelle: hooks: …` line naming the hooks involved. A
malformed provider therefore fails a plain `labelle build` closed, with
`labelle: provider discovery failed: <error>`, exit status 1 and a `failed`
progress record, before anything is generated. For pinned remote providers,
discovery is the same verify-and-extract every provider command performs;
that cost is accepted (it is the integrity model of #414).

## Order

Within one `(step, target)`: every `before` hook, then the core step or its
unique `replace` hook, then every `after` hook. Inside a phase the order is a
topological sort of the `after_hooks` edges that land in that phase; whenever
several hooks are ready, the lexicographically smallest fully qualified ID
runs first. A reference to an earlier phase is accepted and creates no edge.
The plan is a function of the graph alone: the order manifests are read in
(and the order of `.plugins`) never changes it.

**Dependency edges are `after_hooks` only, for now.** The contract also
derives ordering from provider dependencies, but no manifest field declares a
package-to-package dependency yet. When one exists it adds edges here; the
tie-break and everything else stays the same.

## Output layout

Every hook of a step receives the same absolute `output_dir`, which is also
where the core step puts its artifact, so hooks and core agree without any
configuration:

| Step | `output_dir` |
| --- | --- |
| `generate` | `<target_dir>` — the generated tree, `.labelle/<backend>_<target>/` |
| `build`, `run` | `<target_dir>/zig-out/` |
| `bundle` | `<target_dir>/zig-out/bundle/<target>/`, or the resolved `--output` directory |

The CLI creates the directory before the first hook of the step. As part of
this contract the default location of the desktop `.app` moved from
`<target_dir>/zig-out/<Title>.app` to
`<target_dir>/zig-out/bundle/desktop/<Title>.app`; `--output` is unchanged.

## Context

The wire context (§2) for a hook carries `invocation = { "kind": "hook",
"id": <hook id>, "step": <step>, "phase": <phase> }`, the resolved `target`,
the project's `lock_file`, the provider's `config_file` or null, the step's
`output_dir`, the pinned `zig_executable`, and this invocation's `optimize`
and `progress` (`--optimize` and `--progress` as the user passed them, so a
hook builds what the core step builds and speaks the mode the user asked
for). The tool runs with the project root as cwd and no trailing arguments.

`labelle.lock` is written before generation now — immediately after the
package cache is populated and the plugin/core compatibility check ran —
because a `before generate` hook already needs it. A generation that then
fails leaves a fresh lock reflecting the declared pins, which is harmless.

## Failure

Execution is sequential and stops at the first failure. A hook that exits
nonzero fails the command with **the hook's own exit code**, prints
`labelle: hook '<package>/<id>' failed (exit <code>)`, and marks the progress
feed `failed` with that code. Nothing later runs: a failing `before` hook
means the core step never starts, and a failing core step (or `replace`
hook) means no `after` hook runs — contract §6, so a publishing hook can
never ship a stale artifact. For `run`, after hooks run only when the game
exited 0, before the terminal `done` record, and a nonzero game exit is still
the CLI's exit status.

Hooks report under the progress phase of the step they wrap (`generate`,
`compile` for `build`, `run` for `bundle` and `run`) as sub-steps named
`hook <package>/<id>`. When Zig's progress stream has already advanced the
feed from `compile` to `link`, an `after build` hook is a sub-step of `link`
(the phase never moves backward).

For `run`, the core build is the one and only build of the command: the
desktop run path launches the binary the `build` step (or its `replace`
hook) produced, with no warm `zig build` in between, so whatever an `after
build` hook signed, stripped or patched in `zig-out/` is what runs.

## Limitations

- No JSON progress relay or validation for hook (or command) stdout yet: the
  child's stdio is inherited exactly as for provider commands.
- The legacy `labelle ios …` and `labelle android …` subcommand handlers are
  not hook points for `build`/`run`; they only share the `generate` hooks.
  They leave with platform extraction.
- `labelle bundle` is still refused on Linux and Windows before discovery,
  because the core desktop packager is macOS-only and a hook cannot replace
  it. Provider targets (next slice) get their own `bundle` replacement.
- `wasm serve` is interactive: its `done` record lands before the serve loop
  and the `after run` hooks run only once the server returns. A `--watch`
  rebuild re-runs the `generate` and `build` hook phases around its core
  steps exactly as the cold pipeline did (the feed is already terminal, so
  the hooks' sub-step records are not emitted there); a failing hook stops
  that rebuild and keeps the server alive, like a failing core step.
- A `--docker` run whose binary was cross-compiled skips the launch and its
  `after run` hooks with it (nothing ran).

## Verification

`zig build test-provider-dispatch` (also collected by `zig build test`)
covers manifest validation, the planner's order independence, every graph
error, the output-layout contract and the hook wire context; `zig build test`
also covers the watched-rebuild hook plumbing (the serve loop itself is
interactive) and the `link`-phase sub-step. The real-process regression is:

```
zig build
python test/provider_hooks_e2e.py --zig /path/to/zig
```

It drives the actual CLI with a fake assembler (the `plugin_compat` pattern,
with a `.cmd` shim on Windows) and two fixture providers declared in reverse
order. It checks: order regardless of declaration order, an `after_hooks`
edge inverting the tie, the context fields, a failing `before` hook's exit
code with no core build and no `after` hook, a failing core build skipping
`after`, discovery errors (`ReplaceRequiresOwnedTarget`, `DuplicateReplaceHook`,
`MissingHookReference`, `HookPhaseOrder`) at `labelle help` before any
compiler and at `labelle build` after the install but before generation,
`generate` hooks seeing the lock, `run` hooks around the game, an `after
build` edit to `zig-out/` reaching the launched game intact, a cold package
cache failing closed or running a pinned provider's hooks (never skipping
them), `bundle` hooks and the `.app` location on macOS, and the refusal
elsewhere. `test/provider_github_e2e.py` checks that `--accept` refuses a
broken hook graph without writing the lock. CI runs them on Windows, macOS
and Linux.
