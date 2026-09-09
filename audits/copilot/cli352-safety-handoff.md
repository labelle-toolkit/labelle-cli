# CLI352 safety handoff

## Scope

This handoff covers the `measureDirCaseInsensitive` probe and ASTC collision
keying changed on the existing PR branch at `ab7ede6`.

## Safety fixes

- Probe names are randomized with the process IO random source and an atomic
  serial value.
- Both spellings are created with exclusive creation. A preexisting candidate
  causes a retry; no deterministic candidate is deleted.
- Cleanup is limited to files successfully created by the current invocation.
- The lower spelling is also exclusively created on case-sensitive
  filesystems, which avoids treating an unrelated preexisting lower name as a
  case-insensitive match.
- The probe remains safe for concurrent callers because allocation is
  exclusive and candidate names are randomized.

## Unicode identity

For existing source files, collision output names are derived from the
filesystem-resolved source path. This delegates case and Unicode normalization
to the filesystem instead of maintaining a partial Unicode case table. The
regression covers composed `é` and decomposed `e` plus combining acute when
the host filesystem aliases them.

For synthetic paths whose source does not exist, collision keying still has a
best-effort ASCII-only fallback after the directory case probe. It does not
claim to model arbitrary Unicode normalization for paths with no filesystem
identity; callers requiring that guarantee must provide existing sources or
destination entries.

## Validation

`zig build test --summary all` passes, including the existing test suite and
the new probe-preservation and Unicode-normalization regressions.
