# CircleCI Pipeline and Cache Model

This document explains how the CircleCI pipeline in Heads is structured,
what the cache layers mean, and how each coreboot fork saves its own modules cache.

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
- Each x86_coreboot job saves both modules and coreboot caches for its fork.

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

The ppc64 chain mirrors x86:
1. `create_hashes`
2. `ppc64_musl_cross_make` - builds musl-cross-make toolchain, saves cache
3. `ppc64_coreboot` - builds coreboot-talos_2 fork, saves cache
4. (no downstream boards - only one ppc64 board exists)

---

## Cache layers

The x86 pipeline uses hierarchical cache layers:

1. **`{arch}-musl-cross-make-nix-docker-heads-{hash}`**
   - Base toolchain (GCC + musl = musl-cross-make)
   - Paths: `build/{arch}/musl-cross-make-*`, `crossgcc/{arch}`, `install/{arch}`, `packages/{arch}`

2. **`{arch}-coreboot-musl-cross-make-nix-docker-heads-{hash}-{coreboot_dir}`**
   - Includes musl + coreboot toolstack
   - Paths: `build/{arch}/{coreboot_dir}`, `build/{arch}/musl-cross-make-*`, `crossgcc/{arch}`, `install/{arch}`, `packages/{arch}`

3. **`{arch}-modules-coreboot-musl-cross-make-nix-docker-heads-{hash}-{coreboot_dir}`**
   - Includes coreboot + musl + all built modules (FULL)
   - Paths: `build/{arch}`, `install/{arch}`, `crossgcc/{arch}`, `packages/{arch}`

4. **`{arch}-blobs-nix-docker-heads`** are handled separately

Cache key naming: `{arch}-{layer}-nix-docker-heads-{hash}[-{fork}]`

The cache key naming shows the dependency chain: each layer includes everything from the layers below it.

Restore order (most complete to least):
```
1. {arch}-modules-coreboot-musl-cross-make-nix-docker-heads-{modules_hash}-{coreboot_dir}
2. {arch}-coreboot-musl-cross-make-nix-docker-heads-{coreboot_hash}-{coreboot_dir}
3. {arch}-musl-cross-make-nix-docker-heads-{musl_hash}
```

Each `x86_coreboot` job saves both:
- modules cache (full build state)
- coreboot cache (fork-specific toolstack)

---

## Current pipeline details

The current pipeline behavior is:

1. It uses explicit jobs for cache hashing, blob preparation, x86 musl seed,
   x86 coreboot forks (each saves both modules and coreboot caches), generic board
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
9. It decouples ppc64 into musl-cross-make and coreboot jobs (like x86) so each
   saves its cache immediately rather than at the end of a long combined build.

---

## Maintainer checklist

When changing `.circleci/config.yml`, update this document by answering these
questions in order:

1. Did the job graph change?
   Update the `x86 pipeline shape` section and the seed-board list.
2. Did a cache key, restore order, or saved path change?
Update `Cache layers` and `Why musl could rebuild after a cache hit`.
3. Did the change alter current runtime behavior or restore/build semantics?
   Update `Current pipeline details`.
4. Did the change affect the maintenance workflow itself?
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
  edit `ppc64_musl_cross_make` and/or `ppc64_coreboot` and re-check both
  `Cache layers` and the ppc64 chain description.

---

## Invariants

These are the current rules worth preserving unless a deliberate design change:

- Only one job at a time should persist a given workspace chain.
- Blob download is separate from x86 toolchain and coreboot builds.
- Each fork saves both modules and coreboot caches.
- x86 and ppc64 restore lists should prefer the largest valid cache first.
- Same-workflow cache misses can be expected when the broad key is being published during that workflow; this should improve on the next pipeline.
- Musl reuse requires both `crossgcc/<arch>` and `install/<arch>`.
- Each coreboot fork has its own cache keyed by `{coreboot_dir}` to prevent cross-fork contamination.
- ppc64 now uses decoupled musl-cross-make + coreboot jobs, each saving cache immediately.

## How each fork saves its cache

Each `x86_coreboot` job (the first board for each coreboot fork) saves both:
1. **modules cache** - full build state including all built modules
2. **coreboot cache** - fork-specific coreboot toolstack

This means every fork is self-sufficient:
- First board of fork builds everything and saves both caches
- Downstream boards in same fork restore full modules cache
- No separate cache publication job needed

---

## Why musl could rebuild after a cache hit

**Original problem**: Even when cache is restored, musl-cross-make was rebuilt
because the Makefile only checked if `CROSS` env var was set, not if the
compiler actually existed on disk.

**Fix**: The musl-cross-make module now uses `wildcard` to auto-detect if
`crossgcc/<arch>/bin/<triplet>-gcc` exists. If found, it sets CROSS and uses
the `--version` path (no rebuild). If not found, it builds from scratch.

The build logic also requires both:
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

Cold runs are still expensive because:

- Downstream jobs still download the upstream workspace chain.
- A fork starts with cold CircleCI caches because caches are repository-scoped.
- CircleCI restores only the first matching key, so an unexpectedly narrow hit
  can still leave later work to do if the cache contents are incomplete.
- Saving a large cache still requires uploading the selected directories.

---

## When to change this design

Adjust the model only if one of these is true:

- The seed board is no longer representative of the fork workspace.
- The persisted workspace is too large and should be split further.
- The modules cache key is too broad and causes low reuse.
- CircleCI changes workspace or cache semantics.

## Design invariants

- Each coreboot fork saves both modules and coreboot caches, eliminating single-point-of-failure.
- Cache key naming shows the dependency chain: modules includes coreboot includes musl.
- Restore ordering must be explicit and largest-first. If two keys are valid,
  CircleCI uses the first match only.
- Restored build markers can be older than fresh checkout files. Without stamp refresh,
  Make can rebuild musl-cross-make even after a correct modules-cache restore.
- For ppc64, the middle fallback `coreboot+musl` improves reuse when
  `modules` is absent but a richer cache than plain `musl` exists.
- Each x86 coreboot fork saves its own modules cache keyed by `{coreboot_dir}`.
  This prevents cross-fork contamination while enabling fork-specific reuse.
- x86 coreboot forks avoid generic cross-fork fallback keys to prevent
  restoring another fork's coreboot tree.
- ppc64 uses decoupled musl-cross-make + coreboot jobs. Each saves its cache
  immediately rather than at the end of a long combined build.
- musl-cross-make module auto-detects existing crossgcc using wildcard check,
  skipping rebuild when compiler already exists from cache.

## First run observations (pipeline 3789 on circleci-cache-fix branch)

Cold cache run on new pipeline structure:
- x86-musl-cross-make: 30 min (vs baseline 14.5 min) - slower due to new overhead
- ppc64-musl-cross-make: 16 min (vs baseline 18 min) - slightly faster

The Make Board step takes longer in new pipeline because it persists more
data after build (build/, install/, crossgcc/, packages/). The real test is
second run when cache exists - verifies if wildcard fix skips rebuild.

## Cache hash inputs

Cache key hashes intentionally exclude `.circleci/config.yml` to prevent cache
invalidation on CircleCI configuration changes. Add back once cache model is stable
(see TODO in `.circleci/config.yml` create_hashes job).

Key files included in hashes:
- `all_modules_and_patches.sha256sums`: `./Makefile`, `./flake.lock`, `./patches/`, `./modules/`
- `coreboot_musl-cross-make.sha256sums`: `./flake.lock`, `./modules/coreboot`, `./modules/musl-cross-make*`, `./patches/coreboot*`
- `musl-cross-make.sha256sums`: `./flake.lock`, `./modules/musl-cross-make*`


