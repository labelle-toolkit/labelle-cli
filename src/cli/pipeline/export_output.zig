//! The `wasm export --output` path resolver and its destructive-target
//! guard.
const std = @import("std");

/// Resolve the `wasm export --output` value to a path the packager can
/// use. Absolute paths pass through; a relative path is anchored to the
/// project dir so `labelle wasm export ../game --output release` writes
/// under the project, matching where the build output already lives.
/// Caller owns the returned slice.
///
/// SAFETY: the export dir is wiped (`deleteTree`) on every run, so a
/// destructive `--output` — `.`, `..`, the project/cwd root, or any
/// ancestor of them — would delete the user's source tree. Such targets
/// are refused with `error.DestructiveOutputPath` instead. (The
/// complementary "non-empty dir not created by a prior export" guard
/// lives in `export.packageExport`, which owns the deletion.)
pub fn resolveExportOutput(allocator: std.mem.Allocator, project_dir: []const u8, output: []const u8) ![]const u8 {
    // Normalized form of `output` alone (collapses `.`/`..`; keeps a
    // relative path relative). `resolve` does NOT anchor relatives at the
    // cwd in Zig 0.16, so this is pure path math — no filesystem access,
    // which also keeps it unit-testable.
    const norm = try std.fs.path.resolve(allocator, &.{output});
    defer allocator.free(norm);

    const destructive = if (std.fs.path.isAbsolute(norm))
        // Absolute output: refuse the filesystem root (no parent to scope
        // the wipe) or the project dir / an ancestor of it when the
        // project path is itself absolute. Other absolute dirs are still
        // guarded by the non-empty-without-marker check in packageExport.
        std.fs.path.dirname(norm) == null or
            (std.fs.path.isAbsolute(project_dir) and try absTargetHitsProject(allocator, norm, project_dir))
    else
        // Relative output: refuse the project root itself (`.`) or any
        // path that escapes above it (leading `..`) — wiping either would
        // delete the project / a parent tree.
        std.mem.eql(u8, norm, ".") or escapesUpward(norm);

    if (destructive) {
        std.debug.print(
            "labelle wasm export: refusing to use '{s}' as --output\n" ++
                "  the export directory is wiped on every run, and this path is the\n" ++
                "  project directory, an ancestor of it, or the filesystem root.\n" ++
                "  choose a dedicated subdirectory, e.g. --output ./release\n",
            .{output},
        );
        return error.DestructiveOutputPath;
    }

    if (std.fs.path.isAbsolute(output)) return allocator.dupe(u8, output);
    return std.fs.path.join(allocator, &.{ project_dir, output });
}

/// True when a relative, normalized `norm` names the project root
/// itself (`.` is handled by the caller) via an upward escape — i.e. its
/// first path component is `..`. Separator-agnostic: matches both `../`
/// and `..\` so a Windows-style output is caught even if `resolve`
/// emitted the other separator.
fn escapesUpward(norm: []const u8) bool {
    if (std.mem.eql(u8, norm, "..")) return true;
    return norm.len > 2 and std.mem.eql(u8, norm[0..2], "..") and std.fs.path.isSep(norm[2]);
}

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive, so `C:\Proj` and `c:\proj` name the
/// same dir — a destructive-ancestor check must treat them as equal).
fn pathEql(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// True when the absolute, normalized output `norm` is the (absolute)
/// project dir itself or an ancestor of it.
fn absTargetHitsProject(allocator: std.mem.Allocator, norm: []const u8, project_dir: []const u8) !bool {
    const proj_abs = try std.fs.path.resolve(allocator, &.{project_dir});
    defer allocator.free(proj_abs);
    if (pathEql(norm, proj_abs)) return true;
    // `norm` is an ancestor of `proj_abs` only if it extends it at a path
    // boundary — guards against "/foo" matching "/foobar". `isSep` accepts
    // either separator so a mixed-separator input still lands correctly.
    return proj_abs.len > norm.len and
        pathEql(proj_abs[0..norm.len], norm) and
        std.fs.path.isSep(proj_abs[norm.len]);
}

pub const ResolveExportOutputSpec = struct {
    // The export dir is wiped on every run, so a destructive `--output`
    // must be refused before it can delete the user's source tree.
    pub const rejects_destructive = struct {
        test "--output . (the project dir) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "."),
            );
        }

        test "--output .. (an ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", ".."),
            );
        }

        test "--output ../.. (a higher ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "../.."),
            );
        }

        test "--output / (filesystem root) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/"),
            );
        }

        test "an absolute --output equal to the project dir is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj/root"),
            );
        }

        test "an absolute --output that is an ancestor of the project is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj"),
            );
        }

        test "foo/../.. collapsing to an escape is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "foo/../.."),
            );
        }
    };

    pub const accepts_dedicated = struct {
        test "a dedicated subdir under the project is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "release");
            defer a.free(out);
            // Compare against `join` rather than a hardcoded "/" so the
            // assertion holds on Windows (where join uses '\\').
            const want = try std.fs.path.join(a, &.{ "/proj/root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "a nested dedicated subdir is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "dist/web");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "/proj/root", "dist/web" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "an unrelated absolute --output is accepted verbatim" {
            // "/tmp/..." is absolute on POSIX and "rooted" (absolute) on
            // Windows, so it returns verbatim on both.
            const out = try resolveExportOutput(std.testing.allocator, "/proj/root", "/tmp/exports/game");
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings("/tmp/exports/game", out);
        }
    };

    // Windows treats both '/' and '\\' as separators and its filesystem is
    // case-insensitive. These run only on Windows CI (skipped elsewhere)
    // so the directory-wiping guard is actually exercised for those shapes
    // — a hardcoded '/' comparison here would wrongly allow a destructive
    // backslash/drive-letter `--output`.
    pub const windows_separators = struct {
        test "upward escapes via '\\' or mixed separators are rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            for ([_][]const u8{ "..\\secret", "../secret", "foo\\..\\..", "foo/..\\.." }) |esc| {
                try std.testing.expectError(
                    error.DestructiveOutputPath,
                    resolveExportOutput(a, "C:\\proj\\root", esc),
                );
            }
        }

        test "a case-differing absolute ancestor is rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            // Same directory on Windows (case-insensitive) — must be
            // treated as a destructive ancestor, not wrongly accepted.
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(a, "C:\\Proj\\Root", "c:\\proj"),
            );
        }

        test "a dedicated backslash subdir is accepted" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "C:\\proj\\root", "release");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "C:\\proj\\root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }
    };
};
