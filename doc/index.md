# Heads documentation index

Quick reference: read the relevant doc when working on a topic.

| File | What it covers |
|------|----------------|
| `architecture.md` | System architecture: coreboot -> kernel -> initrd, build system, config hierarchy |
| `boot-process.md` | Boot flow stages, ISO boot steps (1-7), [OK]/[~]/[X] marker legend |
| `busybox_perks.md` | GNU vs BusyBox command differences for all tools used in initrd scripts |
| `docker.md` | Docker-based build environment |
| `logging.md` | Log levels (STATUS, WARN, NOTE, INFO, DEBUG, TRACE) usage conventions |
| `modules.md` | Available tools: which are BusyBox applets vs standalone binaries |
| `security-model.md` | TPM, measured boot, trust chain, flash write protection |
| `wp-notes.md` | Flash write protection: PR0 chipset locking, WP# pin, config tables, runtime chain, board coverage |
| `tpm.md` | TPM 1.2 and 2.0 operations |
| `ux-patterns.md` | User interaction patterns (whiptail, CLI menu, confirm dialogs) |
| `iso_boot.md` | ISO boot parameter reference: what each kernel param does and which framework uses it |
| `kexec_handoff.md` | Kexec handoff: screen_info normalization (VLFB), EBDA preservation, sysfb/simpledrm/vesadrm dispatch, driver detection markers, kernel version matrix |
| `patches.md` | Patch creation conventions: naming, multi-patch directories, testing, splitting, forced rebuild after changes |
