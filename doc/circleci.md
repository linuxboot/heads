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

---

## Cache layers

The x86 pipeline uses three cache layers plus blob handling:

1. `musl-cross-make`
2. `coreboot+musl-cross-make`
3. `modules`
4. `blobs` are handled separately

The `modules` cache is the broadest layer. It includes:

- `build/x86`
- `install/x86`
- `crossgcc/x86`
- `packages/x86`

Because this is large, the pipeline does not try to rebuild it inside a
downstream board build just to publish the cache.

---

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

## What went wrong before

The problematic behavior was that `x86_save_modules_cache` ran a full board
build for `EOL_x230-hotp-maximized` before saving the modules cache.

That had two bad effects:

- It saved cache state derived from an x230 build rather than directly from the
  25.09 seed workspace.
- It made the job look like a generic save step while actually doing more build
  work.

The fix is to keep it as a pure save job that publishes the state already
produced by `EOL_t480-hotp-maximized`.

---

## Cold-cache behavior

Even with the corrected job shape, cold runs can still be expensive.

Why:

- Downstream jobs still download the upstream workspace chain.
- A fork starts with cold CircleCI caches because caches are repository-scoped.
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

If you only want faster future runs without delaying current siblings, keep the
separate pure save job model.
