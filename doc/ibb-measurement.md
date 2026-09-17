# IBB measurement and PCR 0

This page covers the Initial Boot Block (IBB) and how hardware measures it into
TPM PCR 0 on Intel boards. PCR assignments, the PCRs Heads seals against, and
the software SRTM chain are documented in [tpm.md](tpm.md); this page does not
repeat them. Read that page for what Heads does with a PCR value, and this page
for what makes PCR 0 carry a firmware measurement at all.

## The IBB and the root of trust

The IBB is the first code executed at the reset vector. In coreboot it is one
or more CBFS files, and the bootblock is always one of them. The IBB must
contain the reset vector and the FIT table, and its size must be a multiple of
16 (coreboot `Documentation/security/intel/txt_ibb.md`). Once measured, the IBB
is the static core root of trust for measurement (SCRTM, reported as
`scrtm_status` in the coreboot CBnT registers).

Two mechanisms can measure the IBB:

* Legacy Intel TXT publishes the IBB as FIT records.
* Intel CBnT (Converged Boot Guard and TXT) carries the digest inside a signed
  manifest and runs a Startup ACM.

Coreboot's own software measurements are a separate chain and land in PCR 2,
not PCR 0 (see [tpm.md](tpm.md)).

## Path 1: legacy Intel TXT

CBFS files can be tagged as part of the IBB when the build has `INTEL_TXT=y`.
The top level Makefile adds `--ibb` to the relevant stages
(`Makefile.mk:884,1406`), and cbfstool then attaches the IBB attribute with a
minimum alignment of 16 (`util/cbfstool/cbfstool.c:1007-1012`). Coreboot adds
the tagged files plus the bootblock to the FIT as type 7, using the bootblock
addition at `src/security/intel/txt/Makefile.mk:46` and the ifittool call at
`:49`; type 7 is `FIT_TYPE_BIOS_STARTUP` in cbfstool
(`util/cbfstool/fit.h:19`). Coreboot's own description states that each IBB is
measured into PCR 0 before the reset vector executes
(`Documentation/security/intel/txt_ibb.md`).

The Dasharo fork used by the NovaCustom boards moved this block to
`src/security/intel/acm/Makefile.mk:30-43`, guarded by
`ifneq ($(CONFIG_INTEL_CBNT_SUPPORT),y)`: on a CBnT board the type 7 IBB
records are deliberately not emitted.

## Path 2: Intel CBnT

On CBnT boards the measured path works differently. Coreboot puts the Startup
ACM in the FIT as type 0x02 when a BIOS ACM file is configured
(`src/security/intel/acm/Makefile.mk:5-16`). Type 0x07 is the legacy BIOS
Startup Module entry and is not used for the IBB here
(`src/arch/x86/include/arch/fit_table.h:18,23`; `util/cbfstool/fit.h:17,19`).
The IBB digest is carried in the signed Boot Policy Manifest instead. Coreboot
can generate an unsigned BPM with a digest list over the image
(`src/security/intel/cbnt/Makefile.mk:58-74`), and the provisioning tool
derives the digest from the CBFS files `bootblock`, `fallback/verstage` and
`fspt.bin` (`3rdparty/intel-sec-tools/pkg/provisioning/cbnt/tools.go:317-331`).

For PCR 0 to receive a measurement, all of the following must be true. None of
them is a Heads or coreboot build option.

1. The platform fuses (FPF) contain Boot Guard with a profile that measures.
   The repository only shows the fuse coupling it consumes: the Key Manifest ID
   and security version number must match the fuses
   (`src/security/intel/cbnt/Kconfig:157-180`).
2. A signed Key Manifest and Boot Policy Manifest are present in the FIT as
   types 0x0b and 0x0c (`src/arch/x86/include/arch/fit_table.h:27-28`), and the
   BPM digest matches the exact image being booted.
3. A Startup ACM is present in the FIT at reset (type 0x02).
4. The ACM extends PCR 0. Coreboot cannot do this part; it can only observe the
   ACM status. `intel_cbnt_inject_ibg_measurements()` returns early unless
   `scrtm_status` is set and the applied policy carries the measured bit
   `CBNT_BP_TYPE_M` (`src/security/intel/cbnt/measurement.c:641-647`,
   `cbnt.h:15-16`).
5. Coreboot reconstructs the event log on Meteor Lake and newer so that
   `cbmem -L` or `tpm2_eventlog` replay matches the PCR 0 value
   (`measurement.c:748-823`; Dasharo fork commits a74cb058c3 and b577aaac21).
   The CRTM version and IBB digest are log only (`measurement.c:777` and
   `:786`); the one PCR 0 value coreboot itself extends is POLICY_DATA
   (`measurement.c:819`). The log helper never extends
   (`src/security/tpm/tspi.h:155-166`).

Things that do not enable a PCR 0 measurement:

* An ACM alone is not sufficient. Without the measured policy bit the code
  returns before doing anything (`measurement.c:646-647`).
* A fused profile that only verifies runs the ACM but measures nothing. The
  Dasharo BGS test documentation reports measured and verified only for
  profiles 3 and 5.
* No Kconfig enables it. `INTEL_CBNT_IBB_FLAGS` only feeds BPM generation
  (`src/security/intel/cbnt/Makefile.mk:63`), and its bit 2 maps to the
  optional PCR 7 auth measurement (`BPM_IBBS_FLAG_AUTH_MEASURE`,
  `measurement.c:24` and `:204`). The PCR 0 gate is the ACM policy word, not a
  build option.
* Intel TXT is not required. CBnT builds select ACM support without TXT
  (`src/security/intel/cbnt/Kconfig:8`; Dasharo fork commit a57a691f20).
* ME state is not an input, and nothing in the measurement path reads it. The
  two ME disable mechanisms are different and neither one is a PCR 0 switch:
  * HAP is a descriptor bit that stops the ME after the platform has started
    (`src/soc/intel/common/block/cse/cse.c:1256-1316`; Meteor Lake U and H
    offset in `include/intelblocks/me_18.h:6-8`). Its state is part of the
    policy word that is hashed into PCR 0, so changing HAP changes the PCR 0
    value, but it does not turn measurement on or off.
  * Soft disable is sent over HECI later in boot and cannot affect a
    measurement that already happened (`cse.c:1167-1223`).

Who does what: the hardware ACM performs the PCR 0 extends, and coreboot only
reconstructs the event log on Meteor Lake and newer. Coreboot's own SRTM
measurements are unchanged and land in PCR 2
(`src/security/tpm/Kconfig:153-155`; see [tpm.md](tpm.md)).

## Provisioning and key material

ACMs are Intel signed. They are not buildable from source and are obtained
under NDA (`Documentation/mainboard/ocp/deltalake.md:52`). The public coreboot
CI config for CBnT points at a fake ACM
(`configs/config.ocp_deltalake_cbnt:3`), and the Dasharo blobs repo ships only
zero filled placeholder manifests
(`3rdparty/dasharo-blobs/cbnt/km_sample.bin` and `bpm_sample.bin`), which the
NovaCustom configs point at (`configs/config.novacustom_v540tu:50-51` in the
Dasharo coreboot tree). That tree used to reference signed ACM files; commit
231257b2c7 removed
`INTEL_TXT_BIOSACM_FILE="MTL_BIOSAC_REL_NT_O1.PW_signed.bin"` and the SINIT
file with the message "ACMs are added at provisioning time by the provisioning
scripts". Coreboot can still carry an ACM when a file is supplied
(`src/security/intel/acm/Makefile.mk:5-16`), but a source build of these boards
does not.

NovaCustom publishes signed production images (file names containing
`btg_prod` and `btg_provisioned`) with hashes at
novacustom.com/novacustom-security. The published V540TU image
`novacustom_v54x_mtl_igpu_v1.0.1_btg_prod.rom` (32 MiB, sha256
`e915ed1eae8b7b91a7a94ad7a75d57a4a077c0e7c6379234755788ca72fb1cd9`, matching
the vendor published hash) does carry the signed material. `cbnt-prov
fit-show` reports a Startup ACM entry (type 0x02) at address `0xffc40000`, a
Key Manifest record (0x0b at `0xffaaaf00`, 853 bytes) and a Boot Policy
Manifest (0x0c at `0xffaaa880`, 913 bytes). `cbnt-prov acm-export` writes the
ACM out as 132096 bytes (sha256
`e9ddab7d96e5cbade4f79a5c5a4dfb5e2a6ebf819400d15398d949eb1ea569a6`, at file
offset 0x1c40000), header date 2024-05-01, TxtSVN 2, SeSVN 5. The ACM header
size field is in dwords, so 33024 dwords is 132096 bytes. The tool's
`acm-show` subcommand cannot parse this ACM because it assumes an RSA 2048
public key while Meteor Lake uses a 384 byte (RSA 3072) key; read the security
version numbers from the raw header instead.

Key material: the FPF stores a SHA 384 hash of the OEM RSA public key. On
NovaCustom TrustRoot units the production key is NovaCustom's own. The
provisioning tool used by 3mdeb prints "Key matches NovaCustom Meteor Lake
signing key", and the 3mdeb advisory post of 2025-12-18 describes the
`eom-key-issue`.

The rule that you must be the OEM to sign manifests is not universal, and the
Clevo leak shows why. Clevo firmware packages shipped the private RSA keys that
sign the Key Manifest and Boot Policy Manifest: `B10717.exe` and
`CreateDeleteBIOSKey.keyprivkey.pem` inside `BootGuardKey.exe`. Binarly
verified that the leaked keys match production Clevo manifests (advisory
BRLY-2025-002, 2025-03-20; CERT VU#538470, 2025-10-13; CVE-2025-11577), with
10 affected devices including Gigabyte and XPG models; initial reporting was by
Thierry Laurion on the Win Raid forum in February 2025. On a machine fused to a
Clevo key, a third party can sign their own Key Manifest and Boot Policy
Manifest and pass Boot Guard. The FPF is one time programmable, so affected
units cannot be rekeyed and no revocation mechanism exists. This does not help
on NovaCustom keyed units, where the production key is held by NovaCustom.

## What an owner can check

All of these are read only and need no special build:

* `pcr0tool dump_registers` prints `ACM_POLICY_STATUS` (measured and verified
  bits, profile, Key Manifest ID, TPM status), `ACM_STATUS` and
  `BTG_SACM_INFO`. It needs access to `/dev/mem` for the ACM status registers;
  see `3rdparty/intel-sec-tools/cmd/pcr0tool/README.md`.
* `tpm2_pcrread` reads the current PCR 0 value.
* `tpm2_eventlog` from an OS, or `cbmem -L` from the recovery shell, shows the
  event log. The Boot Guard entries coreboot records should be present and
  should replay to the PCR 0 value.
* `cbnt-prov show-all` prints the FIT, Key Manifest, Boot Policy Manifest and
  ACM of a firmware image
  (`3rdparty/intel-sec-tools/cmd/cbnt-prov/README.md`).
* On a full SPI flash image use `cbnt-prov fit-show` rather than `pcr0tool
  dump_fit`, which expects a UEFI or CBFS image.
* The vendor firmware setup menu shows Boot Guard register values in the Intel
  ME menu when the platform is fused
  (docs.dasharo.com/dasharo-menu-docs/dasharo-system-features).

Ask the vendor: is the unit fused, and with which profile number; does the
vendor image embed the signed ACM, Key Manifest and Boot Policy Manifest; and
who holds the signing key. Per unit fuse state is not published.

## A different trust model: ownerboot

Adam M. Joseph's ownerboot (codeberg.org/amjoseph/ownerboot) is the opposite
approach. It targets the ASUS KGPE-D16, the MSI AM1-I and ARM64 RK3399 only,
has no Intel target, and does no measured boot at all: the TPM is disabled
(`0023-kgpe-d16-disable-TPM.patch`, `TPM_DEACTIVATE = lib.mkForce yes`). Trust
is anchored in reproducible source builds (`allowNonSource=false`, no
binaries), flash write protection, and owner held OpenBSD `signify` keys; the
term "owner controlled" comes from its `doc/owner-controlled.md`. Caveat: the
signing scripts are declared but not yet published. The contrast matters
because ownerboot removes the vendor, fuse and provisioning dependencies by
removing measured boot, while Heads keeps measured boot and therefore inherits
those dependencies.

## Unknowns

* Whether a platform without fuses runs the ACM and extends an asserted digest.
  Needs the Intel CBnT BWG (document 575623).
* CSME behaviour under HAP on Meteor Lake. No published data.
* Per unit fuse and profile state.
* Whether the signed Key Manifest and Boot Policy Manifest in the published
  images chain to the key hash fused into production units. The images carry
  signed manifests, but the fused key hash is not published.

## References

* coreboot `Documentation/security/intel/txt_ibb.md` and
  `Documentation/security/vboot/measured_boot.md`
* coreboot `Documentation/mainboard/ocp/deltalake.md` ( "ACM binaries ... are
  only required for CBnT enablement. Available under NDA with Intel" )
* Legacy TXT IBB path: `Makefile.mk:884,1406`,
  `util/cbfstool/cbfstool.c:1007-1012`, `util/cbfstool/fit.h:17,19`,
  `src/security/intel/txt/Makefile.mk:39-52`
* CBnT path: `src/arch/x86/include/arch/fit_table.h`,
  `src/security/intel/cbnt/Makefile.mk`,
  `src/security/intel/cbnt/Kconfig`,
  `src/security/intel/cbnt/measurement.c`,
  `src/security/intel/acm/Makefile.mk`, `src/security/tpm/tspi.h`,
  `src/soc/intel/common/block/cse/cse.c`
* Dasharo coreboot fork commits: 231257b2c7, a74cb058c3, b577aaac21, a57a691f20
* Intel documents: CBnT BWG 575623, FIT specification 599500, CSME Security
  Technical White Paper 631900
* Binarly advisory BRLY-2025-002; CERT VU#538470; CVE-2025-11577
* Dasharo BGS test documentation; Dasharo PCR measurements knowledge base;
  Dasharo setup menu documentation
* NovaCustom security page (novacustom.com/novacustom-security) and firmware
  flashing knowledge base
* ownerboot: codeberg.org/amjoseph/ownerboot
