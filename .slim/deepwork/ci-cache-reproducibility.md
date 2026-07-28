# CI Cache Reproducibility Fix — Final Plan

## DONE (on PR #2169)
- CI git-mtime normalization replacing stamp-touch
- gpg2 `--build` + multi-patch directory

## Task 1: musl-cross-make `-j1` + SOURCE_DATE_EPOCH
**File**: `modules/musl-cross-make` line 52
**Change**: Replace `$(MAKE_JOBS)` with `-j1`, add SOURCE_DATE_EPOCH from musl-cross-make's own pinned commit.

```
musl-cross-make_target := \
    SOURCE_DATE_EPOCH=$(shell cd $(build)/$(musl-cross-make_dir) && git log -1 --format=%ct 2>/dev/null || echo 0) \
    OUTPUT="$(CROSS_PATH)" \
    MAKE="$(MAKE)" \
    -j1 \
    "musl-target"
```

**Why**: GCC 9.4.0 already has sorted libtool `find` (committed 2018-07-05). The actual non-determinism source in xgcc/libgcc build is unknown. Serializing the toolchain build eliminates all parallelism-induced effects. Cross-compiler is cached in CI — one-time cost per cache miss (~15-30 min).

## Task 2: busybox reproducibility best practices
**File**: `modules/busybox`
- `KCONFIG_NOTIMESTAMP=1` (Yocto/Buildroot pattern) — prevents AUTOCONF_TIMESTAMP
- `SKIP_STRIP=y` (Yocto/Buildroot) — prevents build path in strip
- Apply `parallel-make-fix.patch` — serializes applet_tables

## Task 3: CACHE_VERSION bump
**After merge**: bump in CircleCI project settings to purge stale caches.

## Task 4: Verify at reporter's commit
Build EOL_t480-hotp-maximized at aedae4ff in ~/heads-clean2, compare with CI artifacts.

## Rejected paths
| Rejected | Reason |
|---|---|
| Guix libtool patch | GCC 9.4.0 already has sorted `find` (lib-1 verified) |
| Bump musl-cross-make | Already at HEAD (227df8b) |
| GCC 15.1.0 | Feature branch, not merged to master |
| SOURCE_DATE_EPOCH from Heads commit | Module identity is from its own pinned source |
| Remove Modules cache | Destructive on build time |
