# RFC: One Android packaging implementation

- Status: Proposed
- Tracking: https://github.com/labelle-toolkit/labelle-cli/issues/405
- Package command architecture: https://github.com/labelle-toolkit/labelle-cli/issues/406
- Runtime extraction: https://github.com/labelle-toolkit/labelle-bgfx/issues/149
- Asset migration: https://github.com/labelle-toolkit/labelle-assembler/issues/759

## Summary

Consolidate APK staging and packaging policy behind one implementation, initially extracted from the CLI's existing Android packager and ultimately owned by the pinned `labelle-android` package. Generated Zig projects, direct CLI builds, and Android Studio exports consume that implementation. Gradle remains a packaging/signing frontend, not a second source of asset, native-library, or manifest policy.

This RFC specifies the contract and migration only. It does not implement package dispatch, change runtime asset loading, or remove existing entry points.

## Problem

Packaging policy currently appears in the CLI's `src/cli/android/package.zig` and `apk_slim.zig`, the assembler's `src/templates/package_apk.txt`, and the Android Studio generator `src/cli/android/studio.zig`. Backend repositories also carry manifests and packaging scripts, including bgfx's Android example and standalone video-decode APK.

The direct CLI path has release stripping, symbol preservation, and asset slimming that the other paths do not consistently share. Studio stages one native library under `src/main/jniLibs` and copies the asset tree. Fixing each path independently preserves the duplication.

Issue #405 originally proposed permanent CLI ownership. Its direction update and RFC #406 instead make `labelle-android` the final owner. Consolidation should create the implementation that moves, without making #405 depend on completing the entire generic package-command framework.

## Goals

- One policy for manifest generation, native-library staging, asset inclusion/compression, and size reporting.
- Equivalent runtime payloads through supported entry points for the same resolved inputs.
- Preserve Debug libraries and retain matching symbols for stripped Release libraries.
- Support current embedded assets and the future APK-loaded assets from assembler #759.
- Preserve Windows support and backend-specific declarations without backend-owned manifest templates.
- Make a breaking migration: existing projects explicitly adopt the new packages and entry points. No compatibility shims or legacy aliases.

## Ownership

| Responsibility | Owner |
| --- | --- |
| Resolve project configuration, target, toolchain and dependency pins | CLI today; generic orchestration under #406 |
| Compile native artifacts and describe runtime assets | Assembler/build producers |
| Declare activity, library identity, rendering requirements and permissions | Backend/runtime provider metadata |
| Validate inputs, stage assets/libraries, render manifests and report sizes | Shared Android packager; eventually `labelle-android` |
| Final APK assembly and signing | Direct packager or Gradle adapter using shared policy |
| Shared Android runtime glue | Separate bgfx #149 work |

## Packaging input contract

Introduce a versioned description of already-built inputs. The exact serialization is an implementation decision; its semantics are required:

- Project identity, application/version metadata, minimum/target SDK, orientation, icon, and explicit debuggable setting.
- Resolved backend/runtime declarations, including native library name, activity class, required rendering features, and permissions.
- Optimize/build variant, ABI, native artifact paths, toolchain identity, output directory, and symbol destination.
- An asset inventory containing source path, APK-relative destination, delivery mode (`embedded` or `apk`), and compression requirement (`stored` or `deflated`) for APK assets.
- Signing configuration references through the existing supported mechanism; never copy credentials into generated metadata or logs.
- Contract version and provider version for compatibility diagnostics.

Reject duplicate destinations, conflicting declarations, missing required inputs, and unsupported contract versions before modifying final outputs. Asset destinations must remain relative to the package root.

### Asset semantics

Do not equate an extension with permission to remove an asset. The inventory describes which bytes the runtime needs and how it opens them.

Videos accessed through file descriptors must be stored, not deflated. APK-loaded textures and other byte-read assets may be deflated. Embedded assets need no duplicate APK copy unless explicitly also consumed at runtime. ASTC PNG fallbacks and packer source art are excluded only when they are not required runtime inputs.

During migration, adapt the current generated-source scan conservatively: retain unknown files rather than silently omit them. Do not require assembler #759 to land first. When its loader switches to APK reads, its producer must also declare those assets as APK-delivered; every frontend must preserve them.

### Native artifacts and symbols

Debug staging preserves the built library. Release staging uses the existing strip policy and keeps an unstripped copy identified by ABI, variant and build identity, so a later build cannot silently replace symbols for an earlier artifact.

Keep the current best-effort behavior for unavailable/failed stripping, with an explicit warning and status in the report. Validation must distinguish a deliberately unstripped fallback from a successfully stripped release. Never strip the producer's original file in place.

## Entry points

### Direct CLI build

The orchestration path generates and builds once, then passes resolved artifacts to the shared package-only operation. Packaging returns output paths, staging/strip outcomes, size information, and a nonzero status on required-step failure.

### Retire generated `zig build package`

Remove the assembler-owned packaging step and its template. Existing generated projects must be regenerated and their callers changed to the supported packaging entry point. Do not add a forwarding shim, legacy alias, or fallback to a global CLI.

The new package-only operation consumes already-built artifacts and must never call top-level generation/build again. Until #406 lands, it can be exposed directly by the consolidated CLI implementation; once package dispatch lands, it belongs to the explicitly pinned provider. Missing providers or unsupported contract versions fail with actionable errors.

### Android Studio / Gradle

Stage variant-specific native libraries and assets. A single stripped Release library under `src/main/jniLibs` cannot also serve Debug. Generation records which native variant produced each staged library; Gradle must not label Debug native code as Release merely because `assembleRelease` was selected.

Use the shared staging operation for each supported variant. Choose an explicit freshness contract: wire preparation into the Gradle task graph, or fail with a regeneration instruction when recorded inputs change. Silent reuse of stale copies is unacceptable. Do not require an implicit network download during Gradle packaging.

The shared manifest model supports frontend-specific rendering: Gradle supplies application ID/version through its DSL, whereas the direct path supplies the corresponding manifest attributes. Equivalent semantics do not require identical XML text.

Gradle's final-archive task reports the actual APK size through the common reporting logic. Exporting a Studio project alone reports staging results, not a claimed APK size. Symbol retention and strip ownership must be explicit so Gradle does not discard the only usable symbol copy.

## Staging lifecycle

Build each staging tree from the current inventory in a generator-owned directory, then publish completed output. Repeated generation must remove assets/libraries that are no longer declared. Cleanup must not follow links into authored assets or delete user-owned Studio files. A failed build cannot leave an older APK presented as the new successful output.

## Backend and example migration

Translate sokol manifest-template specifics into declarations before removing its template. Migrate bgfx's normal Android example and its standalone video-decode APK as distinct consumers. The latter must keep its specialized activity/native entry and diagnostic behavior; deleting its script without a working replacement loses test coverage.

After migration, backend repositories contain declarations and examples, not executable APK packaging policy or production manifest templates. Test fixture manifests may remain when clearly isolated from supported packaging paths.

## Delivery sequence

1. Document and test the existing direct-packager behavior with representative inventories.
2. Extract the package-only contract and shared manifest/staging/reporting functions within the CLI. Preserve existing direct entry points.
3. Adapt Studio and remove the generated Zig packaging step; update callers and add freshness, variant, and error-propagation coverage.
4. Migrate sokol and both bgfx APK consumers, then retire duplicated scripts/templates once their replacements pass.
5. Under #406, move the implementation to pinned `labelle-android` and generic dispatch. Existing projects must explicitly add the package and update their configuration and commands. No forwarding window, implicit provider injection, or legacy aliases.

Consolidation does not wait for the runtime extraction or APK asset-loader migration, but its contract must accommodate both. Publish the replacement and migration instructions together. Consumers must update explicitly; old generated projects are not supported by the new entry points.

## Validation and acceptance

For explicitly migrated Flying Platform with bgfx and a sokol example, exercise the direct and Gradle entry points in Debug and Release. Compare normalized archive inventories and manifest semantics, not whole signed-APK hashes: signing, ZIP metadata, and frontend-generated metadata may differ.

Required checks:

- Required native libraries and assets are present at the expected destinations; embedded duplicates and unused source art are absent.
- Video entries remain stored and playable; APK-loaded asset fixtures are deflated and readable.
- Debug libraries retain debugging information; stripped Release libraries have matching preserved symbols. Missing strip-tool fallback is visible.
- A Debug-to-Release and Release-to-Debug sequence uses the correct native artifact.
- Editing/removing assets and changing native inputs cannot reuse stale staged output.
- Package-only invocation cannot re-enter generation/build; subprocess failures reach the caller. Retired entry points have no forwarding implementation.
- Manifest requirements, orientation, debuggable behavior, icons and library/activity identity agree across frontends.
- Every actual packaging path emits a size report. Studio export reports staging until an archive exists.
- The standalone video-decode example still builds and launches.
- Windows path/tool execution and a POSIX host are covered; physical-device cold start, video playback and background/resume are recorded separately from build-only checks.

Size comparisons use the same game revision, ABI, variant and inputs. Consolidation must not inflate the runtime payload; whole-archive differences must be explained rather than hidden behind a single size threshold.

## Decisions still needed before implementation

- Concrete input format and where the producer emits it.
- Gradle freshness integration: automatic local preparation or explicit regeneration failure.
- Supported variant/ABI matrix for the first migration release.
- Required provider/contract versions and breaking-release ordering across CLI, assembler and backend consumers.

These choices must be recorded in implementation PRs. They do not change the single-owner policy defined here.
