# Provider-declared targets — phase 3b

This documents the target-resolution slice of CLI #406, stacked on the
[v1 contract](provider-contract-v1.md), [project-local
dispatch](provider-local-dispatch.md) and [lifecycle
hooks](provider-hooks.md). `--platform=<t>` now names a target a pinned
provider declares; the CLI keeps no list of platforms. The platform packages
themselves (`labelle-web`, `labelle-android`, …) still remain to be extracted.

## Resolution

Every command that runs the project pipeline (`generate`, `build`, `run`,
`bundle`, and the legacy `wasm`, `android` and `ios` subcommands) resolves
one target before anything is read from the cache, generated or built:

1. The requested name is `--platform=<t>` when given, else the project's
   declared `.platform`. The parsers check only that it is identifier-shaped
   (`[a-z][a-z0-9_-]*`); anything else is `invalid target '<t>' (targets are
   lowercase identifiers; run 'labelle targets')`.
2. `desktop` is the core target and resolves without any provider.
3. Any other name resolves to the pinned provider whose `plugin.labelle`
   declares it in `.targets`. Ownership is validated at discovery, so at most
   one provider can declare a name (`TargetConflict`) and none can declare
   `desktop` (`ReservedTarget`).
4. A name nobody declares fails, before the assembler, a compiler or the
   package cache is touched:

   ```
   labelle: no provider for target 'wasm' in this project; add and pin the package that declares target 'wasm'
     (registry: labelle-web)
   ```

   The second line appears only when the cached registry document — the one
   the last `labelle providers resolve --accept` was resolved against — lists
   a package whose verified cached archive declares the target. The registry
   record itself carries no target declarations (contract §4), so the CLI
   reads the manifest out of the cached archive without extracting or
   running anything, and never invents a name. Nothing is fetched.

The resolved target is a string. It names the generated tree
(`.labelle/<backend>_<target>/`), is passed to the assembler's `generate`,
selects the hook plans, and is the `target` every hook and command context
carries. `labelle targets` prints what a project can resolve:

```
desktop (core)
wasm  provided by labelle-web
```

It is metadata only (like `labelle help`): a broken provider manifest is a
warning on that listing, not a failure.

## The labelle-assembler#378 boundary

`project.labelle`'s `.platform` keeps its strict schema type
(`project_config.Platform`, mirrored by the assembler), and the assembler
still parses `--platform` against that enum. The CLI therefore draws one
explicit line:

- A provider target whose name is a schema platform (`wasm`, `android`,
  `ios`) is handed to the assembler as `--platform <name>`, exactly as
  before. The legacy pipeline branches that key on the enum keep working
  for it.
- A provider target outside the enum can only be generated for by its
  provider's `replace` hook on `generate`. Without one the command stops
  before the assembler runs:

  ```
  labelle: target 'probe-target' is declared by 'fixture' but the pinned assembler cannot generate for it yet (labelle-assembler#378)
  ```

  With one, the provider generates; the core steps it does not replace
  (`build`, `run`) treat the target as the generic host baseline.

What waits for assembler#378: string-resolved platforms in `generate`, the
removal of the `Capability.{wasm,android,ios}` derivation, and the enum
leaving both schema mirrors. Nothing in `project.labelle` changes in this
slice, and `provider_settings.zig` is untouched.

## `labelle bundle`

`labelle bundle [--platform=<t>]` bundles the resolved target (the old
"project platform is X; bundling the desktop target instead" override is
gone):

- `desktop` uses the core macOS packager. The host gate moved from the
  argument parser into the pipeline, after resolution: off macOS it is still
  refused before any build, but only for the core target, and no hook can
  replace it because nobody may own `desktop`.
- A provider target must have a `replace` hook on `bundle`, otherwise
  `labelle: target '<t>' has no bundle replacement; package '<pkg>' must
  declare a `.when = .replace` hook on `bundle`` (`NoBundleReplacement`). The
  hook runs on any host with `output_dir` =
  `<target_dir>/zig-out/bundle/<t>/` (or the resolved `--output`), per the
  [output layout](provider-hooks.md#output-layout).

## Migration

This slice is breaking for every web and mobile project, as the RFC's
migration order requires — no forwarding shim, no alias, no implicit
package injection (RFC #406 "Migration", #410):

- A project that builds for `wasm`, `android` or `ios` — through `.platform`,
  `--platform=<t>`, or `labelle wasm serve|export`, `labelle android …`,
  `labelle ios …` — must add the package that declares that target to
  `.plugins` and pin it (`labelle providers resolve`, then `--accept`).
  Until it does, those commands fail with the no-provider error above.
- The target name is unchanged: `--platform=wasm` stays `--platform=wasm`,
  because the web provider declares the target `wasm`. Only the pin is new.
- The legacy `labelle wasm|android|ios` command words stay reserved built-ins
  until their extraction lands; they route their target through the same
  resolver.
- labelle-studio's web preview builds through `labelle build
  --platform=wasm` and must add and pin `labelle-web`.

## Verification

Unit tests (`zig build test-provider-dispatch`, also collected by `zig build
test`) cover `provider_targets.resolve` (core with no providers, a provider
target, an undeclared target, the schema-name mapping through a provider
only, the diagnostic with and without a registry hint),
`provider_github.cachedRegistryOwner` (a hint only from a verified cached
archive), `args.parseTargetValue` and `parseBundleArgs --platform`. The
real-process regression is:

```
zig build
python test/provider_targets_e2e.py --zig /path/to/zig
```

It drives the actual CLI with a fake assembler that records the target it
was asked for: the no-provider error for `--platform=wasm`, the declared
`.platform` and every legacy subcommand, with no assembler invocation; the
#378 message before the assembler runs; `NoBundleReplacement`; a provider
replacing `generate`/`build`/`bundle` for `probe-target`, including `labelle
bundle --platform=probe-target` running the replacement on every host with
the contract's `output_dir`; a provider owning `wasm` making the assembler
receive `--platform wasm`; and the `labelle targets` listing. CI runs it on
Windows, macOS and Linux.
