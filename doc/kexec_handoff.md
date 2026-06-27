# Kexec Handoff

coreboot → Heads kernel → kexec → target kernel

### kexec --append last-wins rule

kexec's `OPT_APPEND` handler (`kexec-bzImage.c`) **replaces** the append
string on every invocation — it does NOT concatenate:

```c
case OPT_APPEND:
    append = optarg;   /* overwrites previous value */
    break;
```

When `kexec-boot.sh` emits multiple `--append` arguments, the LAST one wins.
A spurious `--append=""` at the end overwrites all earlier parameters,
leaving the kernel with an empty command line — no `root=`, so the
initramfs falls to recovery shell.  `kexec-boot.sh`'s `adjust_cmd_line()`
must always set `adjusted_cmd_line="y"` when done, so that the fallback
`--append=""` never fires.

### Kernel command line construction

The final kernel command line is assembled from three sources:

| Source | Origin | Passed as |
|--------|--------|-----------|
| **Boot entry params** | GRUB `linux` line (everything after kernel path) | `append ...` field in pipe-delimited entry → `kexec-boot.sh`'s `--append` |
| **ADD params** (`-a`) | ISO boot universal params, force-boot `vt.default_red=` | Always prepended to boot entry params |
| **Board ADD** (`CONFIG_BOOT_KERNEL_ADD`) | Board config (e.g. QEMU console settings) | Appended last via `_build_final_cmdline()` |

Processing pipeline in `kexec-boot.sh`:

```
append key handler
  │  cmdline = boot entry's kernel params (e.g. "root=UUID=... ro quiet")
  ▼
adjust_cmd_line()
  │  1. Strip GRUB "---" separator from cmdline
  │  2. Always call _build_final_cmdline(cmdline, add, remove, board_add)
  │     ├─ Apply REMOVE to ADD params        (strip quiet/splash etc.)
  │     ├─ Apply REMOVE to boot params       (strip intel_iommu etc.)
  │     ├─ Combine: "ADD_PARAMS boot_params"
  │     ├─ Enforce ISO-finding keys:         (dedup iso-scan/filename,
  │     │   findiso, img_dev, img_loop,       iso, live-media)
  │     └─ Append Board ADD last             (always wins)
  │  3. Set adjusted_cmd_line="y"            (suppresses fallback --append="")
  ▼
kexec -l <kernel> --initrd=<initrd> --append="<final_cmdline>"
```

If `adjust_cmd_line()` does NOT set `adjusted_cmd_line="y"` (the bug fixed
above), a fallback fires that emits `--append=""` — which overwrites the
real cmdline via kexec's last-wins rule.

### kexec-tools modified_cmdline (bzImage path)

kexec-bzImage additionally supports `--reuse-cmdline` and `--command-line`:

```c
case OPT_REUSE_CMDLINE:
    tmp_cmdline = get_command_line();  // slurps /proc/cmdline
    break;
case OPT_APPEND:
    append = optarg;                   // overwrites previous value
    break;
...
command_line = concat_cmdline(tmp_cmdline, append);
```

`concat_cmdline(base, append)`:
- Both NULL → NULL
- Only append → duplicate of append
- Only base → duplicate of base
- Both set → `"base append"` (space-concatenated)

Heads does NOT use `--reuse-cmdline` or `--command-line` — the cmdline is
supplied entirely via `--append`.  The `--command-line` path is only used
for Xen/multiboot kernels.

### coreboot

Sets up linear framebuffer via libgfxinit (CONFIG_MAINBOARD_USE_LIBGFXINIT)
on pre-Alder Lake boards or via FSP GOP (CONFIG_RUN_FSP_GOP) on Alder Lake
and newer Intel platforms.  Both paths produce a CB_TAG_FRAMEBUFFER entry in
the coreboot table.  `linux_trampoline.S` converts `lb_framebuffer` to `struct screen_info` in boot_params.  Always sets `orig_video_isVGA = 0x70`.

**Boards without the coreboot framebuffer handoff chain:**

These boards skip the libgfxinit/FSP GOP path.  The display handoff chain
(CB_TAG_FRAMEBUFFER → screen_info → vesafb/vesadrm/simpledrm) does not apply.

| Board | GPU init path | Kernel display | User interface |
|-------|-------------|----------------|----------------|
| talos-2 | `CONFIG_NO_GFX_INIT=y` | `CONFIG_DRM_AST=y` | AST GPU initialized by kernel DRM driver; local VGA + BMC |
| EOL_librem_l1um | `CONFIG_NO_GFX_INIT=y` | `CONFIG_DRM_I915=y` (no coreboot framebuffer) | No coreboot GPU init; kernel i915 driver may initialize the iGPU on supported silicon.  BMC/IPMI serial console is the primary/fallback display path.  EOL noted for lack of microcode updates against speculative execution vulns, not because unused |
| librem_l1um_v2 | `CONFIG_NO_GFX_INIT=y` | `# CONFIG_DRM is not set` | No GPU init at any level; BMC/IPMI serial console only |
| KGPE-D16 server | `CONFIG_MAINBOARD_DO_NATIVE_VGA_INIT=y` | `CONFIG_DRM_AST=y`, `CONFIG_VGA_CONSOLE=y` | AST GPU via native VGA init → VGA console → AST DRM → fbcon.  `generic-init.sh` (no GUI).  Dual console: BMC serial (`ttyS1`) + local VGA (`tty0`).  `CONFIG_FB_VESA=y` fallback |
| KGPE-D16 server-whiptail | Same as server | Same as server | Same display path, but boots `gui-init.sh` with whiptail over **serial console** (`CONFIG_SLANG=y`, `CONFIG_NEWT=y`).  No fbwhiptail.  Console output to BMC serial only (`ttyS1`) |
| KGPE-D16 workstation | `CONFIG_MAINBOARD_DO_NATIVE_VGA_INIT=y` | `CONFIG_DRM_AST=y` + `CONFIG_DRM_RADEON=y` + `CONFIG_DRM_AMDGPU=y` + `CONFIG_DRM_NOUVEAU=y` | ASUS AMD server with **external discrete GPU** (NVIDIA/AMD).  Boots `gui-init.sh` with `fbwhiptail` (`CONFIG_FBWHIPTAIL=y`).  Forces NVIDIA POST via `nouveau.config=NvForcePost=1`.  Console to local `tty0` |
| KGPE-D16 workstation-usb_keyboard | Same as workstation | Same as workstation (same kernel config) | Same as workstation plus `CONFIG_USB_KEYBOARD_REQUIRED=y` |

No `CB_TAG_FRAMEBUFFER` or `screen_info` on any KGPE-D16 variant — the coreboot
framebuffer handoff to vesafb/vesadrm/simpledrm does not apply.

### Heads kernel

Heads firmware kernel has `/dev/fb0` as the fbdev console.

All x86 boards run `# CONFIG_DRM is not set` or `CONFIG_DRM=y` without
simpledrm — no DRM/KMS acceleration in the firmware kernel.  `CONFIG_FB_VESA=y`
is enabled on MSI Z690/Z790 and KGPE-D16 as a VESA fallback; disabled on
other boards.

**MSI Z690/Z790:** These desktop boards have no graphics hardware — they route
the CPU's integrated GPU (iGPU) to the display outputs.  An Intel F-suffix
CPU (no iGPU) requires a discrete GPU card.  The iGPU is initialized by
FSP GOP and the display runs via the fbdev console when DRM is not
compiled — the other 8 x86 boards with `# CONFIG_DRM is not set`
carry it as dead config.

### TODO: Clean up SYSFB_SIMPLEFB on boards without DRM

Eight board kernel configs carry `CONFIG_SYSFB_SIMPLEFB=y` despite having
`# CONFIG_DRM is not set` — simpledrm is not compiled, so the
simple-framebuffer device sysfb creates is never consumed.  Functionally
harmless but sloppy.

Boards with dead `SYSFB_SIMPLEFB`:
`linux-c216`, `linux-librem_common-6.1.8`, `linux-novacustom-common`,
`linux-qemu`, `linux-t440p`, `linux-t480`, `linux-w541`,
`linux-x230-legacy`, `linux-x230-maximized`.

Two approaches, pick one:
1. Disable `CONFIG_SYSFB_SIMPLEFB` on these boards (match MSI — cleanest,
   no behavior change, reduces kernel image by a few bytes).
2. Enable `CONFIG_DRM=y` + `CONFIG_DRM_SIMPLEDRM=y` on these boards
   (match newer Librem — enables simpledrm as a second display path,
   but increases kernel image size).

Either is correct; the current mix is not.

### kexec-tools

`setup_linux_vesafb()` reads `/dev/fb0` via `FBIOGET_FSCREENINFO` / 
`FBIOGET_VSCREENINFO`, populates `boot_params.screen_info` for the target
kernel. Preserves the same framebuffer address, resolution, color format.
Sets `VIDEO_TYPE_VLFB` (0x23) — see patch 0003 for rationale.

### Target kernel

Three possible framebuffer paths exist depending on kernel version and
distribution config:

## Target kernel paths

### Path A: simpledrm via SYSFB_SIMPLEFB (Ubuntu, Fedora, NixOS)

```
sysfb → sysfb_parse_mode → "simple-framebuffer" → simpledrm → display
```

`CONFIG_SYSFB_SIMPLEFB=y` + `CONFIG_DRM_SIMPLEDRM=y`.  `sysfb_parse_mode()`
matches our normalized XRGB8888 screen_info against SIMPLEFB_FORMATS,
creates a "simple-framebuffer" platform device, simpledrm binds.

If the kernel also has `CONFIG_FB_VESA=y` (common on Debian, Tails, Fedora),
a race occurs: both vesafb and simpledrm probe the same framebuffer memory.
One wins, the other gets `-EBUSY` (device or resource busy).  Either outcome
is correct — the display works regardless of which driver binds first.
The "Unable to acquire aperture" message from simpledrm is expected and
harmless when vesafb is also present.

### Path B: vesadrm via VLFB fallback (SUSE 7.x)

```
sysfb → fallback (SYSFB_SIMPLEFB=n) → "vesa-framebuffer" → vesadrm → display
```

`CONFIG_SYSFB_SIMPLEFB=n` + `CONFIG_DRM_VESADRM=y`.  sysfb creates
"vesa-framebuffer" (based on orig_video_isVGA=0x23 from our patch 0003),
vesadrm binds.  Stride validation passes because sysfb_create_simplefb()
shifts lfb_size <<= 16 for VIDEO_TYPE_VLFB.

### Path C: legacy vesafb via screen_info (Debian, Tails, Fedora)

```
legacy vesafb (CONFIG_FB_VESA) reads screen_info directly → display
```

`CONFIG_FB_VESA=y`.  The legacy fbdev vesafb driver in
`drivers/video/fbdev/vesafb.c` reads `screen_info` fields directly —
it does NOT use the sysfb platform device.  This means vesafb can bind
even when `CONFIG_SYSFB_SIMPLEFB=y` (simpledrm path) is also present:
both drivers probe the framebuffer memory, and the winner claims the
aperture.  The loser gets `-EBUSY` (harmless).

Common on Debian, Tails, Fedora — these distros compile both
`CONFIG_FB_VESA=y` and `CONFIG_DRM_SIMPLEDRM=y`, resulting in a race
where legacy vesafb typically binds first and simpledrm falls back.

### Summary: which driver wins on which distro

| Distro | SYSFB_SIMPLEFB | FB_VESA | Winner | EBUSY? |
|--------|---------------|---------|--------|--------|
| Ubuntu 26.04 | y | n | simpledrm | no |
| openSUSE 7.x | n | n | vesadrm (DRM via sysfb) | no |
| Debian 13, Tails | y | y | vesafb (legacy fbdev) | simpledrm gets EBUSY |
| Fedora 40 | y | y | vesafb (legacy fbdev) | simpledrm gets EBUSY |
| NixOS | y | y (built-in) | either | possible EBUSY |

## kexec-tools patches (patches/kexec-2.0.26/)

| Patch | Effect |
|-------|--------|
| 0001 | Build fixes (Makefile, purgatory) |
| 0002 | EBDA memory preservation (Xen multiboot) |
| 0003 | screen_info normalization: VLFB (0x23), XRGB8888 masks, stride from /dev/fb0 |

## ISO boot test results (136 ISOs, 2 expected failures)

Tested against all ISOs in ~/Downloads/ISOs/ with `iso-boot-test.sh`.
Results organized by detected driver:

| Marker | Distros | Kernel version | Config |
|--------|---------|----------------|--------|
| `OK:graphics (simpledrm_sysfb)` | Fedora 40, Ubuntu 26.04, NixOS | 6.8 - 6.18 | `SYSFB_SIMPLEFB=y` |
| `OK:graphics (vesadrm)` | openSUSE Tumbleweed | 7.0.11 | `SYSFB_SIMPLEFB=n, VESADRM=y` |
| `OK:graphics (vesafb)` | Fedora, Debian 13, Tails 7.8, PureOS 11, Qubes, NixOS | 6.12+ | `FB_VESA=y` / built-in vesafb |
| `OK:graphics (vesafb)` | Qubes (xen kernel) | 6.x | `FB_VESA=y` (built-in vesafb) |
| `[!]` / `[X]` | CorePlus (TinyCore), Samsung SSD fw | — | No display drivers |

## Marker legend

| Boot menu | Display | Filesystem | Description |
|-----------|---------|------------|-------------|
| `[OK]` | `[OK]:*` + `[OK]` | Both OK | Display works continuously |
| `[~]` | `[~]` or missing fs | Degraded | Display blank briefly DRM reinit, or USB fs has no module |
| `[X]` | `[!]` display | Missing/None | Display blank until i915 init (~3-10s), or ISO not bootable |

## Real hardware test requirements

To validate the framebuffer handoff on real hardware, test each marker
category:

| Category | Test case | What to verify |
|----------|-----------|----------------|
| simledrm_sysfb | Ubuntu 26.04 Live on nv4x_adl | `dmesg \| grep simple-framebuffer` — should show simpledrm bind |
| vesadrm | openSUSE Tumbleweed on nv4x_adl | `dmesg \| grep vesa-framebuffer` — should show vesadrm bind, stride OK |
| vesafb | Debian 13 Live on x230 | `dmesg \| grep vesafb` — should show vesafb bind |
| Display continuity | All three above | Screen should show Heads fb continuously (not blank) until i915 takes over |

Known limitation: the openSUSE kernel has `SYSFB_SIMPLEFB=n` which is
the correct upstream default for 7.x.  Heads cannot enable this from
kexec-tools.  The vesadrm path is the expected fallback and was
verified working on nv4x_adl (FSP GOP / Alder Lake).

**Stride handling:** The actual hardware stride from /dev/fb0
(`fix.line_length`) is preserved.  On FSP GOP boards this is
`width × 4` (32-bit XRGB8888).  On some libgfxinit boards the
framebuffer may be 16-bit RGB565 with stride `width × 2` — the
XRGB8888 color mask normalization is skipped in that case, and
vesafb/vesadrm handle the 16-bit format natively.  Confirm the
actual values via the `dbgprintf` screen_info dump in serial output.

### Diagnosing display issues from the debug log

When kexec produces a torn or blank display on an untested board,
enable debug output via `config-gui.sh → Debugging → Enable debug
output`, reproduce the issue, and extract `/tmp/debug.log`.  Look
for these two lines from `setup_linux_vesafb`:

```
setup_linux_vesafb: /dev/fb0 raw: driver=EFI VGA 1024x768 32bpp stride=4096 base=0xfd000000 r{16,8} g{8,8} b{0,8} rsvd{24,8}
setup_linux_vesafb: screen_info for target: 1024x768x32 stride=4096 base=0xfd000000 size=48 r{16,8} g{8,8} b{0,8} rsvd{24,8}
```

What to check:

| If you see | Then |
|------------|------|
| stride differs between raw and target | Bug — stride was changed. Report with full log |
| stride matches between raw and target | ✅ Correct — hardware stride preserved |
| base address differs between raw and target | Bug — base was corrupted. Report with full log |
| `stride=N` in raw line matches `width × (bpp/8)` | Normal — no alignment padding |
| `stride=N` is larger than `width × (bpp/8)` | Hardware has alignment padding — correctly preserved |
| `16bpp stride=2048` for 1024×768 | 16-bit RGB565 (libgfxinit) — correct, vesafb/vesadrm handles it |
| `32bpp stride=4096` for 1024×768 | 32-bit XRGB8888 (GOP) — correct, simpledrm matches "x8r8g8b8" |

## Verification in decompressed kernel

`_check_kernel_probe_driver()` searches the decompressed kernel for
built-in driver symbols in priority order:

1. `vesadrm_probe` / `vesadrm_platform_driver_init` (VLFB DRM, 7.x SUSE)
2. `vesafb_probe` / `vesafb_driver_init` (VLFB fbdev, 5.x/6.x)
3. `simpledrm_probe` / `simpledrm_platform_driver_init` (simpledrm, 6.x/7.x)

If simpledrm is found, additionally checks for `sysfb_parse_mode`
(symbol unique to CONFIG_SYSFB_SIMPLEFB=y).  Without it, simpledrm
cannot bind because no "simple-framebuffer" device is created.


## Testing status per GPU init path

The simpledrm+sysfb handoff was validated against the following board
configurations.  The `[OK]:graphics` marker confirms compile-time symbols
only — runtime behavior varies by GPU init path and target kernel config.

| GPU init path | Boards | Handoff | Status |
|---------------|--------|---------|--------|
| libgfxinit (pre-Alder Lake) | t420..x230..t480..librem.. | via kexec patches 0001-0003 | Normalized screen_info: VLFB, stride from /dev/fb0, XRGB8888 (if 32-bit) |
| FSP GOP (Alder Lake+) | nv4x_adl..v540tu..msi_z690.. | same | Same normalization, stride from /dev/fb0 (32-bit XRGB8888) |
| No coreboot GPU init | talos-2, librem_l1um | N/A | No CB_TAG_FRAMEBUFFER — see TODO below |

### TODO: Test librem_l1um first gen (no coreboot framebuffer)

The librem_l1um first gen uses `CONFIG_NO_GFX_INIT=y` and `CONFIG_DRM_I915=y`.
Coreboot does NOT populate a `CB_TAG_FRAMEBUFFER`.  When the i915 DRM driver
successfully initializes the GPU, Heads' `/dev/fb0` is `i915drmfb` — NOT
`efifb` or `vesafb`.

The 0003 patch only triggers for `fix.id == "EFI VGA"` or `"VESA VGA"` —
it does NOT handle `"i915drmfb"` or `"inteldrmfb"`.  The old (removed)
0003 patch had a branch specifically for this: it set VLFB for DRM
framebuffers and warned about `drm_leak_fbdev_smem=1`.  That was the
only board configured to use it.

1. Heads kernel has `CONFIG_DRM_I915=y`, fb0 is `i915drmfb`
2. kexec-tools `setup_linux_vesafb()` reads /dev/fb0, populates screen_info
3. 0003 doesn't trigger (fix.id doesn't match)
4. Target kernel reinitializes display via its native i915 DRM path

**Needs testing:** The old 0003 branch for `i915drmfb`/`inteldrmfb` was removed.
If i915 initializes the GPU on this board, the current kexec-tools path will
read /dev/fb0 but NOT trigger the VLFB switch (fix.id doesn't match).  Verify
whether the target kernel boots with correct display via its native i915 DRM
path without our patch intervening.

## Verified per-distro results (138/138 ISOs pass, 2026-06-21)

| Distro | Marker | Kernel driver | Notes |
|--------|--------|---------------|-------|
| Ubuntu 26.04 | `[OK]:graphics (simpledrm_sysfb)` | simpledrm | `SYSFB_SIMPLEFB=y`, resolves `${iso_path}` |
| openSUSE Tumbleweed (DVD+KDE) | `[OK]:graphics (vesadrm)` | vesadrm | `SYSFB_SIMPLEFB=n`, `VESADRM=y` |
| Debian 13 live (KDE+XFCE) | `[OK]:graphics (vesafb)` | vesafb | `FB_VESA=y` + `SYSFB_SIMPLEFB=y` race |
| Debian 13 DVD | `[OK]:graphics (vesafb)` | vesafb | Same |
| Fedora 43 Workstation Live | `[OK]:graphics (vesafb)` | vesafb | Same |
| Fedora 43 Silverblue | `[OK]:graphics (vesafb)` | vesafb | Same |
| Tails 7.8 | `[OK]:graphics (vesafb)` | vesafb | `FB_VESA=y`, live-boot |
| NixOS 25.11 | `[OK]:graphics (vesafb)` | vesafb | stage-1, built-in vesafb |
| PureOS 11 | `[OK]:graphics (vesafb)` | vesafb | casper |
| Kicksecure 18.1 | `[OK]:graphics (vesafb)` | vesafb | live-boot |
| Qubes R4.3.1 | `[OK]:graphics (vesafb)` | vesafb | dmsquash-live |
| CorePlus (TinyCore) | `[~]:drm` | none | No built-in display driver |
| Samsung SSD firmware | `[~]:drm` | none | Not a Linux ISO |

## Kexec-tools screen_info normalization and driver detection

### screen_info normalization (kexec-tools patches 0001-0003)

Heads' kexec-tools patches normalize screen_info in
`kexec/arch/i386/x86-linux-setup.c` before passing it to the target kernel:

| Change | Patch | Effect |
|--------|-------|--------|
| `orig_video_isVGA = 0x23` (VLFB) | 0003 | sysfb creates "vesa-framebuffer".  Avoids 7.x lfb_size stride validation bug. |
| `lfb_linelength = fix.line_length` | 0003 | Preserves actual hardware stride from /dev/fb0 (FBIOGET_FSCREENINFO).  Works for ALL pixel formats — 32bpp (stride=width×4), 16bpp (stride=width×2), or any alignment padding. |
| `lfb_size = (h × stride + 65535) / 65536` | 0003 | In 64K pages; kernel shifts <<= 16 for VLFB.  Uses actual stride from fix.line_length. |
| Color format masks kept from /dev/fb0 | 0003 | NOT overridden.  sysfb_parse_mode() matches red/green/blue masks against SIMPLEFB_FORMATS — transp only checked on FORMAT side.  For 32-bit, hardware masks already match "x8r8g8b8"; for 16-bit, "r5g6b5".  Unmatched formats fall through to vesafb/vesadrm. |
| dbgprintf /dev/fb0 raw + target | 0003 | Both raw hardware values and final screen_info printed for debugging. |
| `_strip_grub_vars()` | initrd | Strips any kernel parameter containing `$` — unresolved GRUB variables like `${iso_path}` are removed entirely.  Universal fallback provides all ISO-finding params with correct absolute paths. |

### How sysfb dispatches

sysfb_init() in `drivers/firmware/sysfb.c`:

```
sysfb_init()
  ├─ sysfb_parse_mode(si, &mode)        // if CONFIG_SYSFB_SIMPLEFB=y
  │   └─ match → "simple-framebuffer"   → simpledrm binds
  │
  └─ fallback (SYSFB_SIMPLEFB=n or parse failed)
      └─ type = screen_info_video_type(si)
          ├─ VIDEO_TYPE_VLFB (0x23) → "vesa-framebuffer"
          │     ├─ kernel 5.x/6.x: CONFIG_FB_VESA → vesafb (fbdev)
          │     └─ kernel 7.x:      CONFIG_DRM_VESADRM → vesadrm (DRM)
          │
```
(Heads' patch sets VIDEO_TYPE_VLFB instead — avoids the 7.x stride bug.)

### Current kernel symbol detection (`functions.sh:_check_kernel_probe_driver`)

`_check_kernel_probe_driver()` searches the decompressed kernel for:

| Symbol | Searched for | Driver | Binds with VLFB? | Assessment |
|--------|-------------|--------|-----------------|------------|
| `vesadrm_probe` | ✅ | vesadrm (DRM, 7.x) | ✅ YES — to "vesa-framebuffer" | **KEEP** — verified on openSUSE 7.x |
| `vesadrm_platform_driver_init` | ✅ | (same) | ✅ | **KEEP** |
| `simpledrm_probe` | ✅ | simpledrm (DRM) | ✅ via SYSFB_SIMPLEFB=y | **KEEP** |
| `simpledrm_platform_driver_init` | ✅ | (same) | ✅ | **KEEP** |
| `sysfb_parse_mode` (add'l) | ✅ | SYSFB_SIMPLEFB | ✅ confirms simple-fb device created | **KEEP** |
| `vesafb_probe` | ✅ | vesafb (fbdev) | ✅ on 5.x/6.x, binds to "vesa-framebuffer" | **KEEP** |
| `vesafb_driver_init` | ✅ | (same) | ✅ | **KEEP** |

## Display driver detection

Display driver detection relies on kernel symbol probing.  The target
kernel's built-in drivers (vesafb, vesadrm, simpledrm) bind via `sysfb_init()`
during kernel initialization, before userspace starts.

`_check_kernel_probe_driver()` decompresses the bzImage and searches for
built-in driver symbols in priority order: `vesadrm_probe`, `vesafb_probe`,
then `simpledrm_probe` (with `sysfb_parse_mode` check for SYSFB_SIMPLEFB).

The boot menu marker starts at `[~]:drm` (degraded: display may work after
DRM reinit) and is upgraded to `[OK]:graphics (<driver>)` when a built-in
driver symbol is found.

## USB filesystem verification

`check_initramfs_for_module()` scans the unpacked initramfs for the USB
filesystem kernel module (ext4.ko, vfat.ko, etc.).  This is essential for
ISO boot — the initramfs must be able to mount the USB drive containing
the ISO file.

## Marker mapping

| Current marker | What it means | Problem | Proposed marker |
|---------------|---------------|---------|-----------------|
| `OK:vesadrm` | vesadrm DM compiled | ✅ correct | Keep |
| `OK:simpledrm_sysfb` | simpledrm + SYSFB_SIMPLEFB | ✅ correct | Keep |
| `OK:vesafb` | vesafb fbdev compiled | ✅ correct | Keep |

## ISO analysis: initramfs frameworks

Seven initramfs frameworks were identified across all tested ISOs.
For framework details, parameter injection, and known limitations, see
[iso_boot.md](iso_boot.md).
See `initrd/etc/functions.sh:_check_kernel_probe_driver()` for the
current symbol priority order.

## Outstanding TODOs

### librem_l1um first gen testing
See TODO section above.  Needs someone with librem hardware.

### EXIT trap code
Fixed the trap parsing to handle BusyBox ash edge cases (group cleanup
in braces, handle empty traps).  Needs testing on hardware.

### Probing gate dialog UX
The probing gate dialog (no loopback.cfg found) says:
"This ISO may not include USB boot support. USB filesystem ext4 is
commonly supported."  This fails to explain:
- USB boot support comes from the distribution's loopback.cfg, which
  is now not even named in the dialog
- "Verify USB modules, drivers and boot compatibility (~30-60s)" lacks
  a "Suggested:" prefix or clear decision guidance
- The option text "Verify USB modules" is inaccurate — the actual
  check verifies kernel display drivers via decompression, not just
  USB modules.  Consider "Verify ISO compatibility (recommended)"
  or similar.
