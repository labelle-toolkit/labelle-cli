## CLI351 handoff — `labelle pack --trim` project root selection + Zig 0.16 fixes

### Artifacts

- **PR**: https://github.com/labelle-toolkit/labelle-cli/pull/383
- **Branch**: `cursor/351-trim-output-project`
- **Commit**: `76d50ea563fb1be853220264b0a24517b74f2ffe`

### What I changed

`src/cli/pack.zig`

- **Project discovery is now tied to the sprites being packed**, not blindly to the shell CWD.
- **When the input dir is not inside any project**, the `--trim` warning **falls back to the `--out-dir` project** (because that’s the project that will *consume* the produced atlas).
- **When the input dir *is* inside a project**, it **takes precedence** over `--out-dir`, even if `--out-dir` points into a different project.
- **Added/expanded unit tests** to lock in:
  - the fallback behavior (input has no project, `--out-dir` has one)
  - input-project precedence (both directions)
  - “no duplicate warning” when input and output are in the same project
  - relative-path ancestor walking including the important `.` append case
  - avoiding probing `.` when the input path escapes upward (`../...`)

### Zig 0.16.0 compile/test fixes

Zig 0.16 removed `std.ArrayList(u8).writer(...)` for the unmanaged `std.ArrayList` type (`array_list.Aligned`).  
The tests now capture formatted output using a tiny `Capture` helper that implements `print(...)` by `std.fmt.allocPrint` + `appendSlice`.

### Fallback / precedence rules (verified by tests)

The guard’s root selection logic is:

- **Primary**: if `input_dir` is inside a project, use that project’s `project.labelle`
- **Fallback**: otherwise, if `out_dir` is inside a project (and `input_dir != out_dir`), use the output project
- **Otherwise**: no warning (best-effort; packing still proceeds)

### How I verified

From repo root:

```sh
zig version
zig build test
```

Notes:
- `zig build test` is noisy (many CLI tests intentionally print warnings/errors while asserting behavior), but **the build exits 0**.
- The fallback/precedence behavior is covered by `test "trim guard: ..."` cases in `src/cli/pack.zig`.

### Test results recorded

- `zig version` → `0.16.0`
- `zig build test` → **exit 0**

### Blockers

- None known.

### PR intent / review notes

- The goal is to avoid **false negatives** where the `--trim` warning silently never triggers because root discovery bottoms out early for relative paths.
- Also avoids **wrong-project reads**: we do not probe `.` when the input path lexically escapes above the cwd (e.g. `../orphan/assets`).

