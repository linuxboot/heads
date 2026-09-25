# Patch creation conventions

The build system applies patches from `patches/` while preparing a module's
source.  Tarball and git modules have different source-preparation branches:
tarball modules extract and patch before creating `.canary`, while git modules
write or update `.canary` before the `.patched` guard decides whether patches
need to be applied.

## Single patch file

`patches/PACKAGE-VERSION.patch`

Example: `patches/kexec-2.0.26.patch` (deprecated — now uses multi-patch directory)

A single `git apply --directory` patch is applied to the prepared module source.
This is the simplest form.  When a single patch grows unwieldy, split into
a multi-patch directory (see below).

## Multi-patch directory

`patches/PACKAGE-VERSION/00N0-description.patch`

Example: `patches/kexec-2.0.26/0001-build-fixes.patch`

When the directory `patches/PACKAGE-VERSION/` exists, the build applies
all `*.patch` files inside it in alphabetical order.  Use numeric
prefixes to control ordering.

Prefer the multi-patch directory when:
- The package needs 3+ independent changes
- Different people maintain different patches
- Patches benefit from separate descriptions

## How the build applies patches

The `.canary` recipe has two source branches:

```text
tarball: extract to build/$ARCH/$base_dir/ → apply patches → create .canary
git:     init/reset/clean pinned source → write/update .canary
         → if .patched absent: process zero or more patches → create .patched
         → .configured → .build
```

> **Git-source recovery note:** deleting `.canary` on an existing git source
> enters resynchronization.  The path removes the existing `origin`, adds it
> again, fetches, hard-resets, cleans, and reapplies patches; an existing
> `origin` is not itself a failure.  Network, permission, fetch, reset, clean,
> and patch failures remain possible.  Removing/recreating the source tree is
> conservative recovery if that path fails.

For either branch when patches are being applied:

```text
if patches/$name.patch exists → git apply the single patch
if patches/$name/ exists      → git apply each *.patch in sorted order
```

A git module touches untracked `.patched` after its patch branch completes.
The branch processes zero or more configured patches and then creates the marker
even when no patches are configured; when `.patched` already exists, the branch
is a no-op.  `.canary` records the intended repo/revision for the initialized or
reset source; `.patched` is the separate git patch-completion marker, not a
universal target between `.canary` and `.configured`.  During git resynchronization,
`git clean -df` runs before the `.patched` guard and removes that untracked
marker, so the following patch branch runs.  Tarball
modules do not normally create `.patched`; if that marker already exists when
`.canary` is missing, the tarball branch reverses and reapplies the patches,
removes the stale marker, and only then recreates `.canary`.

`.configured` depends on `.canary`; `.build` depends on `.configured` and
dependency-module `.build` stamps.  See
[modules.md](modules.md#build-lifecycle) for the complete lifecycle and
[modules.md](modules.md#rebuild-helpers) for the actual invalidation steps.

## Creating a patch

### From a modified source tree

```
# 1. Keep the original somewhere:
tar xf packages/x86/kexec-tools-2.0.26.tar.gz --strip 1 -C /tmp/orig/

# 2. Make your changes in the working tree (build/x86/kexec-tools-2.0.26/)
# 3. Generate the patch:
diff --git a/kexec/arch/i386/x86-linux-setup.c b/kexec/arch/i386/x86-linux-setup.c
--- a/kexec/arch/i386/x86-linux-setup.c
+++ b/kexec/arch/i386/x86-linux-setup.c
...
```

The `diff --git` header and `---`/`+++` lines MUST use `a/` and `b/`
prefixes.  `git apply --directory` strips the `a/`/`b/` automatically.

### From intermediate stages

For sequential patches that modify the same file:

```
# Stage 1: apply only your first change set
# diff original → stage-1 → patch 01

# Stage 2: apply second change set on top
# diff stage-1 → stage-2 → patch 02
```

Use `diff -u` between the two stages.  The line numbers in `@@` headers
must reference the file state that this patch is applied to.  `git apply`
calculates offsets automatically from context.

## Testing patches

```
# Apply to a clean tarball copy:
rm -rf /tmp/test && mkdir -p /tmp/test
tar xf packages/x86/PACKAGE-VERSION.tar.gz --strip 1 -C /tmp/test/

for patch in patches/PACKAGE-VERSION/*.patch; do
    patch -p1 -d /tmp/test --dry-run < "$patch" || break
done
```

For single-file patches, `patch --dry-run` is faster and clearer than
`git apply`.  `git apply` works in-repo; `patch` is portable and gives
better error messages.

## Splitting a monolithic patch

When a single large patch grows unwieldy:

1. Create `patches/PACKAGE-VERSION/` directory
2. Split hunks by goal into separate `NN-name.patch` files
3. Remove the old `patches/PACKAGE-VERSION.patch`
4. Test all patches apply sequentially

Each patch should target one goal: a build fix, a feature, a bug fix.
Multi-file changes for the same goal stay in one patch.

## Common pitfalls

- **Line numbers in `@@` headers**: Generate diffs from the exact state
  the patch will be applied to.  For sequential patches, diff from the
  intermediate state, not the original.
- **Context precision**: If `patch` reports "fuzz" or rejects, the
  context lines don't match the target file.  Add more context lines
  (increase `diff -U` context).
- **Tab vs space**: The extracted tarball may have different whitespace
  than your editor.  Generate patches from files that were actually
  extracted from the tarball.
- **`git apply` vs `patch`**: The build uses `git apply --directory`,
  which strips `a/`/`b/` prefixes.  Make sure `---` and `+++` lines
  use `a/`/`b/` paths.
- **Timestamps**: `diff -u` adds timestamps to `---`/`+++` lines.
  `git apply` ignores them.  Remove them for cleaner patches or keep
  them; both work.

## Build directory permissions

The build prepares tarball or git module source and applies patches inside
`build/$ARCH/`.
When the build runs in Docker (the default), extracted files and
directories are owned by `root`.  User-level tools (`cp`, `rm`,
`touch`, editors) cannot modify them.

To work around this when debugging patches:

```bash
# Copy patched files into the root-owned build tree:
pkexec cp /tmp/patched-file.c build/x86/kexec-tools-2.0.26/kexec/arch/i386/

# Or take ownership of the whole build tree:
pkexec chown -R $(id -u):$(id -g) build/
```

The actual build runs as root inside Docker and applies patches from
`patches/` automatically.  Only use `pkexec` for manual development
iterations outside Docker.

After creating a patch, `.canary` sentinels do not track patch files, so source
preparation must be invalidated.  For tarball modules, remove `.canary`.  For
git modules, remove `.canary` to trigger the normal remove/re-add `origin`,
fetch/reset/clean, and patch-reapply path.  If network, permission, fetch,
reset, clean, or patch handling fails, remove/recreate the source tree as
conservative recovery.  Downstream `.configured`/`.build` removal is optional
for tarballs and normally unnecessary when the whole git source tree is removed.
Do not rely on touching prepared source alone.
