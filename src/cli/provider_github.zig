//! GitHub metadata + a project pin file. No registry service or implicit updates.
//!
//! Thin root: the implementation lives in `provider_github/`, split by
//! responsibility. This file re-exports the public API unchanged.
const pin = @import("provider_github/pin.zig");
const files = @import("provider_github/files.zig");
const archive = @import("provider_github/archive.zig");
const sources = @import("provider_github/sources.zig");
const registry_cache = @import("provider_github/registry_cache.zig");
const preview = @import("provider_github/preview.zig");
const resolve_mod = @import("provider_github/resolve.zig");
const fetch_mod = @import("provider_github/fetch.zig");
const test_fixtures = @import("provider_github/test_fixtures.zig");
const registry_lookup = @import("provider_github/registry_lookup.zig");

pub const lock_name = pin.lock_name;
pub const preview_name = preview.preview_name;
pub const registry_url = resolve_mod.registry_url;
pub const registry_cache_dir = registry_cache.registry_cache_dir;
pub const registry_cache_file = registry_cache.registry_cache_file;
pub const Pin = pin.Pin;
pub const Document = pin.Document;
pub const parse = pin.parse;
pub const checkPins = pin.checkPins;
pub const archivePath = archive.archivePath;
pub const cacheRoot = files.cacheRoot;
pub const Sources = sources.Sources;
pub const Extractions = sources.Extractions;
pub const registry_hint_scan_limit = registry_cache.registry_hint_scan_limit;
pub const cachedRegistryOwner = registry_cache.cachedRegistryOwner;
pub const cachedRegistryNamespaceOwner = registry_cache.cachedRegistryNamespaceOwner;
pub const RegistryLookup = registry_lookup.Lookup;
pub const RegistryOwnerHint = registry_lookup.OwnerHint;
pub const RegistryMiss = registry_lookup.Miss;
pub const RegistryMissReason = registry_lookup.Reason;
pub const registry_accepted_name = registry_lookup.accepted_name;
pub const registry_offline_env = registry_lookup.offline_env;
pub const lookupRegistryOwner = registry_lookup.lookupOwnerFromEnv;
pub const PreviewEntry = preview.PreviewEntry;
pub const preview_schema = preview.preview_schema;
pub const Preview = preview.Preview;
pub const writePreview = preview.writePreview;
pub const loadPreview = preview.loadPreview;
pub const checkPreview = preview.checkPreview;
pub const resolve = resolve_mod.resolve;
pub const fetch = fetch_mod.fetch;
pub const fetchCommand = fetch_mod.fetchCommand;
pub const default_downloader = fetch_mod.default_downloader;
pub const projectRepo = pin.projectRepo;
pub const testProviderArchive = test_fixtures.testProviderArchive;

/// Fresh archive extractions performed by any `Sources` — the test seam that
/// shows which rebuilds unpacked an archive and which reused one.
pub var extraction_count: usize = 0;

// Every module is referenced here so its tests run: a file reached only
// through lazily analyzed declarations would silently drop its tests.
test {
    _ = pin;
    _ = files;
    _ = archive;
    _ = sources;
    _ = registry_cache;
    _ = preview;
    _ = resolve_mod;
    _ = fetch_mod;
    _ = test_fixtures;
    _ = registry_lookup;
}
