OFALG fixes summary

This document lists recent OFLAG (optimization flag) fixes applied in the repository and where to find validation evidence.

- zlib
  - Fix: packaging enforces CFLAGS=-Oz
  - Validation: V=1 builds on x86 & ppc64 show -Oz usage in compile lines
  - Logs: build/x86/log/zlib.log, build/ppc64/log/zlib.log

- cryptsetup2
  - Fix: pre-configure substitutions applied (remove -O3 from Argon2 templates and normalize libtool hardcode flags)
  - Commit: fac65ebc7e
  - Validation: V=1 x86 & ppc64 builds validated; grep shows no remaining -O3 in cryptsetup2 build trees
  - Logs: build/ppc64/log/cryptsetup2.log, build/x86/log/cryptsetup2.configure.log

- cryptsetup (older, not used)
  - Packaging change: pre-configure sed added to normalize `-O[0-9]+`/`-Os` -> `-Oz` and `CXXFLAGS` set to `-g -Oz` in `modules/cryptsetup`.
  - Note: this module is not used by current boards (`cryptsetup2` is the active module); change applied for completeness; validation is optional.
  - Files: `modules/cryptsetup`

- cryptsetup
  - Fix: packaging-time pre-configure sed added to normalize `-O[0-9]+`/`-Os` -> `-Oz` and remove Makefile backup artifacts; `CXXFLAGS` set to `-g -Oz` for defensive coverage of C++ tests.
  - Validation: **pending** — V=1 x86 & ppc64 builds to be run to confirm no `-O2`/`-Os` occurrences in final build logs
  - Logs: build/x86/log/cryptsetup.configure.log, build/ppc64/log/cryptsetup.configure.log

- slang
  - Fix: minimal pre-configure sed applied replacing -O2 with -Oz
  - Validation: logged CFLAGS show -Oz in build output
  - Logs: build/x86/log/slang.log

- libaio
  - Fix: pre-configure sed applied to replace `-O[0-9]+` and `-Os` with `-Oz`.
  - Validation: V=1 x86 & ppc64 builds show `-Oz` in compile and link lines (see `build/x86/log/libaio.log` and `build/ppc64/log/libaio.log`).

- tpmtotp
  - Fix: guarded pre-build sed replaces -O[0-9]+ with -Oz in generated Makefile fragments (Makefile, util/Makefile, libtpm/Makefile)
  - Validation: V=1 builds completed for x86 & ppc64 and grep shows no remaining -O3 in build trees
  - Logs: build/x86/log/tpmtotp.log, build/ppc64/log/tpmtotp.log

- tpm2-tools
  - Fix: pre-configure sed normalizes `-O[0-9]+`/`-Os` -> `-Oz` and `CFLAGS`/`CXXFLAGS` set to `-g -Oz` defensively in `modules/tpm2-tools`.
  - Validation: V=1 x86 build (board `msi_z790p_ddr5`) completed successfully and compile/link lines show `-Oz` only; configure-wrapper occurrences were addressed. TODO: run ppc64 validation if relevant.
  - Logs: build/x86/log/tpm2-tools.log, build/x86/tpm2-tools-5.6/config.log

- dropbear
  - Fix: packaging-time sed normalizes optimization flags to `-Oz` (replaces `-O[0-9]+` & `-Os` with `-Oz`) and configure is invoked with size-friendly env vars where applicable. We intentionally do not strip `-funroll-loops`/`-fomit-frame-pointer` at packaging time because reintroducing them into bundled libs did not change final binary sizes in our tests.
  - Validation: V=1 x86 build shows `-Oz` in `configure` and build logs. However, a size regression was observed versus the earlier CircleCI artifact: `dropbear` 184,832 → 241,248 (+56,416 bytes), `ssh` 176,416 → 233,048 (+56,632 bytes). Local builds used GCC 15.1.0 while the earlier artifact used GCC 9.4.0; most likely root cause is compiler/toolchain or upstream package-version changes rather than residual `-O` flags.
  - Logs: build/x86/dropbear-2025.88/config.log
  - Recommended follow-ups: 1) Rebuild dropbear under GCC 9.4 to confirm toolchain impact; 2) run symbol/section diffs to localize growth; 3) prototype linker/build mitigations (`-ffunction-sections/-fdata-sections` + `--gc-sections`, strip, or LTO) if desired.

- kexec-tools
  - Fix: packaging-time pre-configure sed normalizes `-O[0-9]+`/`-Os` -> `-Oz` and removes Makefile backup artifacts; sed is run during `kexec-tools_configure` (pre-configure) so generated artifacts no longer contain legacy `-O` tokens.
  - Validation: V=1 x86 & ppc64 builds show `-Oz` only in compile/link lines; evidence: `build/x86/log/kexec-tools.log`, `build/ppc64/log/kexec-tools.log`. Post-scan totals: `Oz:157`, no `-O2`/`-Os` occurrences remaining in build logs.
  - Notes: prior scan reported mixed `-Os`/`-O2`/`-Oz`; packaging-time change resolved those mixed occurrences in validated builds.

Notes & next steps
- .bak files left in the build trees are artifacts of the reversible sed step; remove them for cleanliness if desired or keep them as audit evidence.
- cryptsetup (legacy module) restored to HEAD and is not referenced by any boards; no packaging-time changes are required for that module.
- For cross-arch completeness, consider running per-package V=1 builds on additional arches (arm64, riscv) for packages that still show legacy -O tokens in non-built files.
