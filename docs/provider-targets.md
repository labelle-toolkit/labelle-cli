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
one target, in two halves, before anything is generated, locked or built:

1. The requested name is `--platform=<t>` when given, else the project's
   declared `.platform`. The parsers check only that it is identifier-shaped
   (`[a-z][a-z0-9_-]*`); anything else is `invalid target '<t>' (targets are
   lowercase identifiers; run 'labelle targets')`. A Windows reserved device
   name (`con`, `nul`, `prn`, `aux`, `com1`-`com9`, `lpt1`-`lpt9`) is
   identifier-shaped but names directories no Windows host can create
   (`.labelle/<backend>_<t>/`, `zig-out/bundle/<t>/`), so it is refused with
   its own reason — by the parsers, and at manifest validation for a
   declared target or a hook's target (`ReservedDeviceTarget`).
2. `desktop` is the core target and resolves without any provider.
3. Any other name resolves to the pinned provider whose `plugin.labelle`
   declares it in `.targets`. Ownership is validated at discovery, so at most
   one provider can declare a name (`TargetConflict`) and none can declare
   `desktop` (`ReservedTarget`). *Pinned* is load-bearing: a remote package
   read from the ordinary package cache without an integrity pin
   (`Provider.verified == false`) is discovered, and `labelle targets` lists
   its declaration marked `(unpinned)`, but it never resolves a target —
   owning one means generating, building or bundling for it, so the owner is
   held to the same boundary as a hook that runs, even when it declares no
   hook and nothing else would ever ask for its pin:

   ```
   labelle: target 'wasm' is declared by remote package 'labelle-web', which is unpinned; a target's provider must be pinned. Run labelle providers resolve, review the pins, then repeat with --accept.
   ```

4. A name nobody declares fails:

   ```
   labelle: no provider for target 'wasm' in this project; add and pin the package that declares target 'wasm'
     (registry: labelle-web)
   ```

   The second line comes only from the cached registry document, the one
   the last `labelle providers resolve --accept` was resolved against.
   Nothing is fetched, and the CLI never invents a name.

   - A **schema-2** document publishes target ownership
     ([contract §4](provider-contract-v1.md#registry-schema-2-ownership-tables-and-defaults)),
     so the hint is a lookup by target in that table and reads no archive.
     This works even when none of the owner's releases is cached, which is
     the usual case for a package the project has never added.
     `--accept` checked each claim against the verified manifest of every
     release it pinned.
   - A **schema-1** record carries no declarations, so the CLI falls back
     to scanning cached archives. It reads the manifest out of each one
     without extracting or running anything. Each archive read decompresses
     a whole release on a scratch arena freed before the next. The scan
     stops at the first owner or after `registry_hint_scan_limit` cached
     releases, so a large registry bounds the cost of a diagnostic rather
     than the other way round.

The two halves are the **name** and the **ownership**. The name is settled
from the string alone, first thing: `desktop` is core, any other name is
*provisionally* a provider target. That is enough for everything the
pipeline needs before a provider can be read — the target directory, the
progress feed, the schema platform the pre-install steps key off — and for
two verdicts that need no provider: a project with no `.plugins` cannot own
a provider target and is refused before anything is read, written or built,
and `labelle bundle` of the core target is refused off macOS before any
install.

Ownership is decided as early as it can be. Provider discovery is
authoritative only after the assembler's `install` populated the package
cache (a declared remote package has no readable manifest before it; see
[provider hooks](provider-hooks.md#discovery-and-the-graph)) — but for a
provider target the pipeline first runs the same metadata-only discovery
`labelle targets` does (cached manifests, no installer). When that read
every declared package, the verdict it reaches is the one the post-install
check would reach, so it lands right there: an identifier-shaped typo
(`--platform=waasm`), a name no declared package owns, or an unpinned remote
owner is refused before `.prebuild`, the assembler resolution, the ASTC
prepass or the install run — nothing is read, written or built. A manifest
that fails discovery fails it closed there too: the install cannot mend a
manifest that is already readable. Only while a declared remote package is
not readable yet (cold cache, no pin) does the verdict wait for the
post-install discovery, which stays the authoritative check: a declared
package that does not declare the requested name is refused there — after
the install, before the lock, generation or any compiler, with a `failed`
progress record naming the refusal — `no provider for target`, or
`unpinned provider for target` when the declaring package is remote and
unpinned — and nothing else in the target directory. The `labelle-assembler#378` gate and the bundle-replacement check
below need the hook plans, so they land at the post-install point. `labelle
wasm serve --no-build` installs nothing and confirms the name against the
providers discoverable as-is, like `labelle targets`.

The resolved target is a string. It names the generated tree
(`.labelle/<backend>_<target>/`, from the provisional name, so a refused
target leaves only the `failed` record there), is passed to the assembler's
`generate`, selects the hook plans, and is the `target` every hook and
command context carries. `labelle targets` prints what a project can
resolve:

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
  (`build`, `run`) treat the target as the generic host baseline. The ASTC
  prepass is not among them: it keys on the requested target, and a target
  outside the enum has no capability table (`labelle astc` refuses the name),
  so the prepass is skipped rather than run with the derived `desktop` — a
  provider owns its target's asset pipeline.

What waits for assembler#378: string-resolved platforms in `generate`, the
removal of the `Capability.{wasm,android,ios}` derivation, and the enum
leaving both schema mirrors. Nothing in `project.labelle` changes in this
slice, and `provider_settings.zig` is untouched.

## `labelle bundle`

`labelle bundle [--platform=<t>]` bundles the resolved target (the old
"project platform is X; bundling the desktop target instead" override is
gone):

- `desktop` uses the core macOS packager. The host gate moved from the
  argument parser into the pipeline, right after the name is settled: off
  macOS it is still refused before any install or build, but only for the
  core target, and no hook can replace it because nobody may own `desktop`.
- A provider target must have a `replace` hook on `bundle`, otherwise
  `labelle: target '<t>' has no bundle replacement; package '<pkg>' must
  declare a `.when = .replace` hook on `bundle`` (`NoBundleReplacement`),
  decided with the hook plans after discovery (after the install, before
  any build). The hook runs on any host with `output_dir` =
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
target, an undeclared target, an unpinned remote owner, the schema-name
mapping through a provider only, the diagnostic with and without a registry
hint), `provider_github.cachedRegistryOwner` (a schema-2 table lookup with no
archive cached; for schema 1, a hint only from a verified cached archive,
and the bounded scan), `provider_registry` (schema-2 parsing, ownership
conflicts, lookup by target and namespace), `provider_dispatch.discoverAll` (the
unresolved packages of a partial view), the reserved-device-name rule
(`provider_contract.targetName`, the manifest's `targets` and hook targets,
`args.parseTargetValue`) and `parseBundleArgs --platform`. The real-process
regression is:

```
zig build
python test/provider_targets_e2e.py --zig /path/to/zig
```

It drives the actual CLI with a fake assembler that records the target it
was asked for: the no-provider error for `--platform=wasm`, the declared
`.platform` and every legacy subcommand, with no assembler invocation; the
early verdict for a local provider that does not own the name, including a
typo that leaves a `.prebuild` marker step unrun (while a resolving target
runs it); a remote package on a cold cache deferring the verdict to after
the install (the `failed` record) and, unpinned, refused as an owner both
after the install and — warm — before it; the #378 message before the
assembler runs; `NoBundleReplacement`; a provider replacing
`generate`/`build`/`bundle` for `probe-target`, including `labelle bundle
--platform=probe-target` running the replacement on every host with the
contract's `output_dir`; the ASTC prepass running for `desktop` and not for
`probe-target`; a provider owning `wasm` making the assembler receive
`--platform wasm`; and the `labelle targets` listing. CI runs it on Windows,
macOS and Linux. The Docker WASM build in `ci.yml` declares the repo's own
`test/fixtures/wasm-provider` (a module plugin whose manifest owns `wasm`)
because the platform packages are not extracted yet.
