# CircleCI Pipeline and Cache Model

This document explains the Heads CircleCI pipeline structure, cache
layers, and job types.

See also: [development.md](development.md), [docker.md](docker.md),
[architecture.md](architecture.md).

---

## Key concepts

### Workspace

A workspace passes data from an upstream job to downstream jobs in the
same workflow run.

- Workspaces help downstream jobs in the current pipeline, not future ones.
- Persisting the same paths from multiple upstream jobs into one
  downstream job causes fan-in errors in CircleCI.

### Cache vs workspace

| Type | Scope | Purpose |
|---|---|---|
| Workspace | Per-workflow | Share build outputs between jobs |
| Cache | Cross-pipeline | Avoid redoing expensive operations (compiler builds, dependency downloads) |

### Job types

Two job types exist for x86 board builds in `.circleci/config.yml`:

**`x86_coreboot` (seed)**: One per unique toolchain.  Saves modules +
coreboot fork caches.
- `restore_cache` with 3-key fallback (Modules → Coreboot fork → Musl)
- `build_board` — builds crossgcc (if `.heads-toolchain` stamp absent),
  then builds the board ROM
- `persist_to_workspace`: saves `packages/x86 build/x86 crossgcc/x86 install/x86`
- `save_cache` ×2: Modules cache (full `build/x86`) + Coreboot fork
  cache (`build/x86/{coreboot_dir}` + crossgcc + musl + packages)

**`build` (downstream)**: Plain board builds.  No `restore_cache`/`save_cache`.
All inputs come from the seed's workspace (including crossgcc, blobs, musl,
and fork source for same-fork boards).  For Dasharo shared-toolchain boards
where the seed uses a different fork (nv4x), fork source is cloned fresh
during `make` (seconds).

---

## Cache model

All cache key hashes are computed once per pipeline by `create_hashes`
and are global — every job gets the same hashes.  Per-seed
differentiation comes solely from the `{coreboot_dir}` suffix.

### Three layers (+ blobs)

Restore order (first hit wins):

| Priority | Layer | Key hash | Scope | Contents | Invalidates on |
|---|---|---|---|---|---|
| 1 | Modules | `all_modules_and_patches` | Per-seed | ALL of `build/{arch}` + crossgcc + install + packages | Any module/patches change |
| 2 | Coreboot fork | `coreboot_musl-cross-make` | Per-seed | `build/{arch}/{coreboot_dir}` + crossgcc + musl + packages | Coreboot + musl-cross-make + coreboot patches + flake.lock |
| 3 | Musl | `musl-cross-make` | Per-arch | `crossgcc/{arch}` + `build/{arch}/musl-cross-make-*` + install + packages | Musl-cross-make change (rare) |

Blobs are handled separately as a 4th cache layer (`x86-blobs-...`), shared
by all x86 jobs.  Restored before seeds run, persisted to workspace.

### Hit scenarios

- **Modules hits**: All fork source, crossgcc, and modules restored.
  `make` finds `.heads-toolchain`, skips crossgcc rebuild.
  Only changed artifacts rebuild.
- **Coreboot fork hits, Modules misses** (e.g., non-coreboot module
  changed): Fork source and crossgcc restored.  Modules rebuild.
  Saves ~30-40 min of crossgcc build time.
- **Musl only hits**: No coreboot fork source or coreboot crossgcc (`build/{arch}/{coreboot_dir}`).  The musl toolchain (`crossgcc/{arch}`) is present, but the coreboot fork tree -- including coreboot's own crossgcc under `util/crossgcc/` -- must be built from scratch.
- **Nothing hits**: Everything from scratch.

### Why two saves per seed

Each seed saves 2 caches: Modules (superset) and Coreboot fork (subset).
The Coreboot fork cache is a narrow fallback — if only non-coreboot
modules change, Modules misses but Coreboot fork hits, avoiding an
unnecessary crossgcc rebuild.  Musl is arch-dependent, saved once per
architecture (x86, ppc64), not per seed.

### `build` jobs inherit cache through workspace

`build` jobs have no `restore_cache` or `save_cache` steps.  They inherit
cache results indirectly through the workspace chain:

1. The seed runs `restore_cache` — on a warm run, the Modules or Coreboot
   fork cache hits, restoring crossgcc (`.heads-toolchain` stamp) and
   fork source into `build/{arch}/`.
2. The seed runs `build_board` — `make` finds `.heads-toolchain`, skips
   crossgcc rebuild.  Builds the ROM.
3. The seed runs `persist_to_workspace` — saves everything under
   `build/{arch}/`, including restored cache artifacts.
4. The `build` job runs `attach_workspace` — gets the seed's full
   `build/{arch}/` directory, including the crossgcc that was restored
   from cache in step 1.

The cache hit happens upstream, but the `build` job consumes the result.

For same-fork `build` jobs (e.g. 25.09 downstream boards), the seed's
fork source is inherited through the workspace -- no clone needed.

For Dasharo shared-toolchain `build` jobs where the seed uses a different
fork (nv4x), the fork source directory is not in the workspace.  Each
such `build` job clones its own fork fresh during `make` (seconds).
This prevents them from independently cache-missing under their own
`{coreboot_dir}` suffix and triggering a redundant crossgcc rebuild.

---

## Pipeline shape

Job names in CircleCI follow conventions to make their purpose clear
in the UI:

- Cache key creators include `[cache keys]`: `create_hashes [cache keys]`
- Blob downloads include blob type: `x86_blobs [ME GBE IFD]`
- Seeds include their upstream coreboot base: `[seed:coreboot-VERSION]`
- Build jobs use their board target name (no suffix)

The x86 chain:
`create_hashes [cache keys]` → `x86_blobs [ME GBE IFD]` →
`x86-musl-cross-make [cross compiler]` → `x86_coreboot` seeds →
`build` jobs (parallel).

The ppc64 chain (no blobs, single board):
`create_hashes [cache keys]` → `ppc64-musl-cross-make [cross compiler]` →
`ppc64_talos_2 [seed:coreboot-talos-2]`.

### Step details

All jobs run under the `heads-docker` executor (pinned Docker image at
`tlaurion/heads-dev-env` with SHA256 hash — see [docker.md](docker.md)
for the image definition and reproducibility details, and
[flake.nix](../flake.nix) for the Nix-based build environment used to
generate it).  The shared `build_board` command runs `make V=1 BOARD=<target>`,
refreshes restored build stamps to prevent spurious rebuilds, and archives
build logs on failure.

1. **`create_hashes`**: Computes sha256 hashes (cache keys) from source
   files and persists `tmpDir/` to workspace.  Four hash files are created:
   - `all_modules_and_patches.sha256sums`: `Makefile`, `flake.lock`,
     `patches/`, `modules/` — used by **Modules** cache layer
   - `coreboot_musl-cross-make.sha256sums`: `flake.lock`,
     `modules/coreboot`, `modules/musl-cross-make*`, `patches/coreboot*`
     — used by **Coreboot fork** cache layer
   - `musl-cross-make.sha256sums`: `flake.lock`,
     `modules/musl-cross-make*` — used by **Musl** cache layer
   - `blobs_listing.sha256sums`: `blobs/**/*.sh` — used by **Blobs** cache
   All downstream jobs get the same global hashes (`tmpDir/` from workspace).
   Per-seed differentiation comes from the `{coreboot_dir}` suffix on cache
   keys, not from the hash.

2. **`x86_blobs`**: Downloads x86 firmware blobs (ME, GBE, IFD).
   Restores blob cache keyed on blob script listing hash (`x86-blobs-...`).
   Persists `blobs/` to workspace.  Only for x86 (ppc64 has no blobs).

3. **`x86-musl-cross-make [cross compiler]`**: Builds musl-cross-make arch-specific toolchain
   (GCC + musl).  Restores/saves musl cache (`x86-musl-...`).
   Persists `packages/x86 build/x86 crossgcc/x86 install/x86` to workspace.

4. **`x86_coreboot` seeds** (one per unique toolchain): Build crossgcc + ROM.
   Restores cache (Modules → Coreboot fork → Musl).  Saves 2 caches.
   Persists workspace for downstream `build` jobs.

5. **Downstream `build` jobs**: Attach workspace from seed, build ROM.
   No cache operations.  Same-fork boards inherit fork source from workspace;
   Dasharo shared-toolchain boards clone fork source fresh during `make`.

### ppc64 chain

- `ppc64-musl-cross-make [cross compiler]`: Same pattern as x86 but
  ppc64-arch.  Restores/saves ppc64 musl cache.  No blobs step (ppc64
  has no firmware blobs).
- `ppc64_talos_2 [seed:coreboot-talos-2]`: Single seed for
  `coreboot-talos_2`.  Restores/saves ppc64 modules + coreboot caches.
  Only one ppc64 board exists, no downstream `build` jobs.
- The ppc64 cache model mirrors x86 without the blobs layer.
- See [architecture.md](architecture.md) and [config.md](config.md) for
  ppc64 board and build details.

### Seeds (5 total)

Seed job names in CircleCI include their upstream coreboot base in
`[seed:coreboot-VERSION]` format:

| Job name in CircleCI | Seeds | Upstream base |
|---|---|---|
| `novacustom-nv4x_adl [seed:coreboot-24.12]` | 4 Dasharo families (8 boards) | coreboot 24.12 |
| `librem_14 [seed:coreboot-24.02.01]` | 8 purism boards | coreboot 24.02.01 |
| `kano [seed:coreboot-mrchromebox]` | none (standalone) | MrChromebox fork (coreboot 26.03) |
| `EOL_t480-hotp-maximized [seed:coreboot-25.09]` | 28 x86 boards | coreboot 25.09 |
| `EOL_librem_l1um [seed:coreboot-4.11]` | none (standalone) | coreboot 4.11 |
| `ppc64_talos_2 [seed:coreboot-talos-2]` | none (standalone) | Dasharo fork for Talos 2 |

### Downstream Dasharo boards (all `build` jobs)

All depend on `novacustom-nv4x_adl [seed:coreboot-24.12]`, inherit its
crossgcc via workspace:

- `novacustom-v560tu`, `novacustom-v540tu`
- `UNTESTED_msi_z690a_ddr4`, `UNTESTED_msi_z690a_ddr5`
- `UNTESTED_msi_z790p_ddr4`, `msi_z790p_ddr5`
- `UNTESTED_nitropad-ns50`

---

## Dasharo shared toolchain

### Why the dasharo forks share a compiler

Four Dasharo board families (nv4x, v56, msi_z690, msi_z790) all use
the same `github.com/dasharo/coreboot` repository.  Their
`util/crossgcc/sum/` files are byte-identical — verified by `diff -r`.
They share identical packages: gcc-14.2.0, binutils-2.43.1,
nasm-2.16.03, clang-18.1.8.

In `modules/coreboot`, `dasharo_nv4x` is the toolchain provider (empty
second arg to `coreboot_module()`).  `dasharo_v56`, `dasharo_msi_z690`,
and `dasharo_msi_z790` pass `dasharo_nv4x` as their toolchain argument,
consuming its crossgcc instead of building their own.

**Why this works despite different FSP blobs**: The crossgcc is a
compiler (GCC, binutils, assembler, linker).  It is independent of the
code it compiles, just like `/usr/bin/gcc` can compile any C program
regardless of which headers that program includes.  FSP blobs in
`3rdparty/dasharo-blobs/` are inputs to the compiler (headers and
binaries linked into the ROM), not part of the compiler itself.  Each
board builds against its own fork's FSP blobs with its own `.config`;
only the compiler binary is shared.  Each fork's `3rdparty/dasharo-blobs/`
submodule commit differs (nv4x at 668d80d, v56/z690/z790 at 8dce760),
but that only affects the ROM build, not the compiler.

### CI structure

Only `novacustom-nv4x_adl` is an `x86_coreboot` seed.  All other Dasharo
boards are `build` jobs.  The cache key hash is global (from `modules/`
and `patches/`).  If v56, z690, and z790 had their own seeds, each would
have a different `{coreboot_dir}` suffix (`coreboot-dasharo_v56`,
`coreboot-dasharo_msi_z690`, `coreboot-dasharo_msi_z790`) and would
independently cache-miss and rebuild the same crossgcc on a cold cache.
Making them `build` jobs eliminates that — they never try to restore
cache, so they cannot cache-miss.  They get the crossgcc from
`novacustom-nv4x_adl`'s workspace.

### Re-verification after upstream rebase

When a Dasharo fork rebases to a newer coreboot release, check that the
shared toolchain is still compatible:

```bash
diff -r build/x86/coreboot-dasharo_nv4x/util/crossgcc/sum/ \
       build/x86/coreboot-dasharo_NEW/util/crossgcc/sum/
```

If the diff is non-empty, the new fork needs its own toolchain module.
The `{coreboot_dir}` suffix for its cache key would be the fork-specific
directory name.

### 24.02 cluster (not shared)

`coreboot-24.02.01` (upstream tarball), `coreboot-purism` (Purism git
fork), and a stale `build/x86/coreboot-dasharo` checkout (no active
boards, no module definition) share identical sum files (gcc-13.2.0,
binutils-2.41, nasm-2.16.01, clang-16.0.6).  `purism` is the only
maintained/CI consumer of this toolchain -- sharing would not save any
crossgcc builds since purism is the sole consumer, and would add
complexity (different source types: tarball vs git fork).
(Unmaintained boards that reference 24.02.01 exist under
`unmaintained_boards/` but are not built in CI.)

---

## Maintainer edit map

When changing `.circleci/config.yml`, update this document:

- **Job graph changed**: Update Pipeline shape and seed list.
- **Cache key, restore order, or saved path changed**: Update Cache
  model and `Why musl could rebuild`.
- **Runtime or rebuild semantics changed**: Update Pipeline details.
- **New Dasharo fork added**: In `modules/coreboot`, set its toolchain
  to `dasharo_nv4x` if crossgcc sum files match; add a `build` job in
  `.circleci/config.yml` depending on `novacustom-nv4x_adl`.  If sum
  files differ, add a new `x86_coreboot` seed.
- **New non-Dasharo fork added**: Add an `x86_coreboot` seed in
  `.circleci/config.yml`.

---

## Why musl could rebuild after a cache hit

**Problem**: Even when cache is restored, musl-cross-make was rebuilt
because the Makefile only checked if `CROSS` env var was set, not if
the compiler actually existed on disk.

**Fix**: The musl-cross-make module uses `wildcard` to auto-detect if
`crossgcc/<arch>/bin/<triplet>-gcc` exists.  If found, it sets CROSS
and uses the `--version` path (no rebuild).  If not found, it builds
from scratch.

The build logic also requires both:
- the compiler binaries under `crossgcc/<arch>`
- the installed sysroot under `install/<arch>`

If the cache only restores the compiler tree but not the installed
headers and libraries, the generic module build rules still have
missing outputs and musl is rebuilt.  That is why `install/{arch}` is
stored alongside the compiler in every cache layer.

A second reuse problem: restored stamp files can be older than freshly
checked-out source files in CI.  When that happens, GNU Make can decide
that `.configured` and then `.build` are stale even though the restored
outputs are complete.  The CI job refreshes restored stamps before
invoking `make` so restored musl-cross-make trees are reused.

---

## Cache hash inputs

Hashes intentionally exclude `.circleci/config.yml` to prevent cache
invalidation on CI config changes.  Files used:

- `all_modules_and_patches.sha256sums`: `./Makefile`, `./flake.lock`,
  `./patches/`, `./modules/`
- `coreboot_musl-cross-make.sha256sums`: `./flake.lock`,
  `./modules/coreboot`, `./modules/musl-cross-make*`,
  `./patches/coreboot*`
- `musl-cross-make.sha256sums`: `./flake.lock`,
  `./modules/musl-cross-make*`
