# Patch creation conventions

The build system extracts a tarball and applies patches from `patches/`.
The naming convention determines how patches are applied.

## Single patch file

`patches/PACKAGE-VERSION.patch`

Example: `patches/kexec-2.0.26.patch` (deprecated — now uses multi-patch directory)

A single `git apply --directory` patch is applied to the extracted source.
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

From `Makefile`:

```
extract tarball to build/$ARCH/$base_dir/
if patches/$name.patch exists  → git apply single patch
if patches/$name/ exists        → git apply each *.patch in sorted order
touch .patched to mark completion
```

On next build, the `.patched` file prevents re-extraction and re-patching.

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

The build extracts tarballs and applies patches inside `build/$ARCH/`.
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

After creating a patch, see [modules.md](modules.md#build-lifecycle) for
how to trigger a rebuild — `.canary` sentinels do not track patch files.
