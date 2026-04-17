# CircleCI Pipeline and Cache Model

This document explains how the current CircleCI pipeline in Heads is structured,
what the cache layers mean, and why `x86_save_modules_cache` exists as a
separate job.

See also: [development.md](development.md), [docker.md](docker.md),
[architecture.md](architecture.md).

---

## Goals

The CircleCI pipeline is optimized for two constraints:

- Avoid CircleCI workspace fan-in errors.
- Reuse expensive build outputs across pipelines without delaying unrelated
  board builds more than necessary.

The current layout favors a linear x86 seed chain followed by parallel board
builds.

---

## Key concepts

### Workspace

A workspace is data passed from an upstream job to downstream jobs in the same
workflow run.

- Workspaces help sibling jobs in the current pipeline.
- Workspaces are downloaded fresh by downstream jobs.
- Persisting the same paths from multiple upstream jobs into one downstream job
  causes fan-in problems in CircleCI.

### Cache

A CircleCI cache is stored for reuse by later pipeline runs in the same
repository.

- Caches help future pipelines.
- Caches do not speed up sibling jobs in the same workflow run.
- Forks do not share caches with the upstream repository.

This distinction matters for understanding `x86_save_modules_cache`: it is a
cache publication job, not a producer for current sibling board builds.

---

## x86 pipeline shape

The x86 chain is intentionally linear until a seed board has produced a usable
workspace:

1. `create_hashes`
2. `x86_blobs`
3. `x86_musl_cross_make`
4. `x86_coreboot` seed jobs, one per coreboot fork
5. Downstream board builds for each fork, in parallel

For the coreboot 25.09 branch, the seed board is `EOL_t480-hotp-maximized`.
That job produces the workspace used by the other 25.09 boards in the same
workflow.

Other x86 forks follow the same pattern:

- `novacustom-nv4x_adl` seeds the `coreboot-dasharo_nv4x` fork
- `novacustom-v560tu` seeds the `coreboot-dasharo_v56` fork
- `librem_14` seeds the `coreboot-purism` fork
- `EOL_t480-hotp-maximized` seeds the `coreboot-25.09` fork
- `EOL_librem_l1um` seeds the `coreboot-4.11` fork
- `UNTESTED_msi_z690a_ddr4` seeds the `coreboot-dasharo_msi_z690` fork
- `UNTESTED_msi_z790p_ddr4` seeds the `coreboot-dasharo_msi_z790` fork

The downstream `build` jobs for each family consume the workspace from the
relevant seed job instead of rebuilding the fork toolchain from scratch.

The ppc64 side is intentionally different: `ppc64_talos_2` is a single linear
job because there is only one ppc64 board in the workflow.

---

## Cache layers

The x86 pipeline uses three cache layers plus blob handling:

1. `musl-cross-make`
2. `coreboot+musl-cross-make`
3. `modules`
4. `blobs` are handled separately

The ppc64 pipeline uses the same three logical layers, but because Talos II is
the only ppc64 target they are produced and consumed from one job.

The `modules` cache is the broadest layer. It includes:

- `build/x86`
- `install/x86`
- `crossgcc/x86`
- `packages/x86`

The narrower `musl-cross-make` and `coreboot+musl-cross-make` layers also need
the installed sysroot under `install/<arch>`, not just `crossgcc/<arch>`. The
musl module is only considered complete when both the compiler binary and its
installed headers and libraries are available.

Restore order also matters. CircleCI stops at the first matching cache key, so
the current branch restores the broad `modules` cache before the narrower
`musl-cross-make` cache where that broader cache is a valid superset.

Cache timing also matters. A job can correctly miss `modules` in the current
workflow if that broad cache key was not published by an earlier pipeline yet.
In that case, restore falls back to narrower caches for the current run, while
the publication job still creates the broad key for subsequent pipelines.

Because this is large, the pipeline does not try to rebuild it inside a
downstream board build just to publish the cache.

---

## Current pipeline details

The current pipeline behavior is:

1. It uses explicit jobs for cache hashing, blob preparation, x86 musl seed,
   x86 coreboot seeds, a pure x86 modules-cache publication step, generic board
   builds, and the single ppc64 Talos II build.
2. It uses a pinned `heads-docker` executor so the toolchain environment is
   stable across jobs.
3. It clears only `build/<arch>/log/*` before a build, not the restored build
   trees themselves.
4. It keeps x86 blob preparation separate from toolchain and firmware builds.
5. It keys x86 coreboot caches by fork so one fork cannot restore another
   fork's build tree.
6. It restores the largest valid cache first, because CircleCI stops at the
   first matching key.
7. It stores `install/<arch>` together with the compiler and package trees so a
   restored musl toolchain still has its sysroot.
8. It refreshes restored `.configured` and `.build` stamps before invoking
   `make`, so fresh checkout mtimes do not trigger a redundant rebuild of an
   already restored musl-cross-make tree.
9. It keeps ppc64 as a single-job path because there is no ppc64 fan-out to
   optimize.

---

## Maintainer checklist

When changing `.circleci/config.yml`, update this document by answering these
questions in order:

1. Did the job graph change?
   Update the `x86 pipeline shape` section and the seed-board list.
2. Did a cache key, restore order, or saved path change?
   Update `Cache layers` and `Why musl could rebuild after a cache hit`.
3. Did a job stop being a pure cache publication step or start building
   additional targets?
   Update `Why x86_save_modules_cache is separate`.
4. Did the change alter current runtime behavior or restore/build semantics?
  Update `Current pipeline details`.
5. Did the change affect the maintenance workflow itself?
   Update this section too.

If you cannot summarize the change in one of those sections, the document is
missing a section and should be extended rather than worked around.

---

## Edit map

Use this map when modifying the pipeline:

- Add or remove a cache hash input:
  edit `create_hashes` in `.circleci/config.yml` and update `Cache layers` here.
- Add or remove x86 blob preparation:
  edit `x86_blobs` and update `x86 pipeline shape` plus `Cache layers`.
- Add or remove an x86 coreboot fork seed:
  edit the `x86_coreboot` workflow entries and update the seed-board list in
  `x86 pipeline shape`.
- Add or remove downstream boards for a fork:
  edit the `build` workflow entries and verify the seed dependency still points
  to the correct fork seed.
- Change what makes musl reusable:
  update the save/restore paths in `.circleci/config.yml` and re-check the
  explanation in `Why musl could rebuild after a cache hit`.
- Change ppc64 behavior:
  edit `ppc64_talos_2` and re-check both `Cache layers` and the note that ppc64
  is intentionally single-step.

---

## Invariants

These are the current rules worth preserving unless there is a deliberate
design change:

- Only one job at a time should persist a given workspace chain.
- Blob download is separate from x86 toolchain and coreboot builds.
- `modules` is the broadest cache layer and should be first in restore lists
  where it is a valid superset.
- x86 and ppc64 restore lists should prefer the largest valid cache first.
- Same-workflow cache misses can be expected when the broad key is being
  published during that workflow; this should improve on the next pipeline.
- Musl reuse requires both `crossgcc/<arch>` and `install/<arch>`.
- `x86_save_modules_cache` is a pure save job, not a build job.
- ppc64 remains a single Talos II path until there is real ppc64 fan-out.

## Why `x86_save_modules_cache` is separate

`x86_save_modules_cache` exists so the 25.09 seed job does not spend extra time
saving the full modules cache before releasing its dependents.

Its intended behavior is:

1. Wait for `EOL_t480-hotp-maximized`
2. Attach that seed workspace
3. Save the broad x86 modules cache
4. Exit without building another board

This means:

- Other 25.09 boards are delayed by `EOL_t480-hotp-maximized`
- They are not delayed by `x86_save_modules_cache`
- The saved cache benefits future pipelines, not the current sibling jobs

If `x86_save_modules_cache` builds another board, the job is doing the wrong
thing. That makes it a cache-warming build job instead of a cache publication
job, and it can save the wrong state.

---

## Why musl could rebuild after a cache hit

Seeing `crossgcc/<arch>` in a restored cache is not enough to prove that
`musl-cross-make` can be skipped.

The current build logic treats musl as reusable only when the restored cache
still contains both:

- the compiler binaries under `crossgcc/<arch>`
- the installed sysroot under `install/<arch>`

If the cache only restores the compiler tree but not the installed headers and
libraries, the generic module build rules still have missing outputs and musl
is rebuilt.

That is why the current branch stores `install/x86` and `install/ppc64` in the
musl and coreboot cache layers, not only in the broad modules cache.

There is a second reuse problem to watch for: restored stamp files can be older
than freshly checked-out source files in CI. When that happens, GNU Make can
decide that `.configured` and then `.build` are stale even though the restored
outputs are complete. The current CI job refreshes restored `.configured` and
`.build` timestamps before invoking `make` so restored musl-cross-make trees are
reused instead of spending several minutes rebuilding for timestamp reasons
alone.

---

## Cold-cache behavior

Even with the corrected job shape, cold runs can still be expensive.

Why:

- Downstream jobs still download the upstream workspace chain.
- A fork starts with cold CircleCI caches because caches are repository-scoped.
- CircleCI restores only the first matching key, so an unexpectedly narrow hit
  can still leave later work to do if the cache contents are incomplete.
- Saving a large cache still requires uploading the selected directories.

So a separate save job avoids extending the seed job's critical path, but it
does not eliminate workspace download cost.

---

## When to change this design

Adjust the model only if one of these is true:

- The seed board is no longer representative of the fork workspace.
- The persisted workspace is too large and should be split further.
- The modules cache key is too broad and causes low reuse.
- CircleCI changes workspace or cache semantics.

## Recent lessons (April 2026)

- Successful cache creation does not imply immediate same-workflow reuse.
  Example pattern observed: x86 modules miss in `x86_musl_cross_make`, then the
  key is published later by `x86_save_modules_cache`, and next pipelines can hit
  it.
- Restore ordering must be explicit and largest-first. If two keys are valid,
  CircleCI uses the first match only.
- Restored build markers can be older than fresh checkout files. Without stamp
  refresh, Make can rebuild musl-cross-make even after a correct modules-cache
  restore.
- For ppc64, adding `coreboot+musl` as a middle fallback improves reuse when
  `modules` is absent but a richer cache than plain `musl` exists.
- For x86 coreboot forks, avoid generic cross-fork fallback keys to prevent
  restoring another fork's coreboot tree.

If you only want faster future runs without delaying current siblings, keep the
separate pure save job model.
