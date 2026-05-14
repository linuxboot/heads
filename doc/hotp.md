# HOTP & USB Security Dongle

This document covers how `seal-hotpkey.sh` interacts with `hotp_verification`
and the NK3-specific behavior Heads scripts need to handle.

See also: [security-model.md](security-model.md), [ux-patterns.md](ux-patterns.md),
[tpm.md](tpm.md).  Return code definitions live in
`build/x86/hotp-verification-*/src/return_codes.h`.

---

## NK3 `info` command output and exit codes

`hotp_verification info` communicates over CCID (NK3) or HID (Pro/Storage/Librem
Key).  stdout lines are tab-indented (`\t`).  The presence check in
`seal-hotpkey.sh` looks for `Connected device status:` in the output, regardless
of exit code.

| Scenario | Exit code | `Connected device status:` | Counter line |
|---|---|---|---|
| Slot configured | 0 | yes | `Secrets app PIN counter: N` |
| Slot unconfigured, OATH alive | 0 | yes | `PIN is not set - set PIN...` |
| OATH SELECT fails (Path B) | 3 | no (returns early) | not printed |
| No dongle connected | 1 | no | not printed |

**Path A** (unconfigured slot, applet present): `status_ccid()` returns
`RET_NO_PIN_ATTEMPTS` (31), `parse_cmd_and_run()` converts to exit 0.
The counter line reads `"PIN is not set - set PIN before the first use"`.

**Path B** (OATH SELECT fails): `send_select_ccid()` returns non-0x9000,
`status_ccid()` returns `RET_COMM_ERROR` (29), `check_ret()` returns early.
No `Connected device status:` is printed; exit code 3.

## NK3 PIN counter mapping

| PIN type | Source | Counter path | Factory default |
|---|---|---|---|
| Secrets App PIN | OATH applet (`Tag_PINCounter` TLV) | `Secrets app PIN counter:` | 8 |
| GPG Admin PIN | PGP applet (ISO 7816 `0xCA`) | `GPG Card counters: Admin` | 3 |
| GPG User PIN | PGP applet (same `0xCA`) | `GPG Card counters: User` | 3 |

`seal-hotpkey.sh` uses the Secrets App PIN (called `admin_pin_retries` for
historical reasons).

## seal-hotpkey.sh retry logic

All counter queries go through `query_pin_retries()` which retries
`hotp_verification info` until a valid numeric counter is obtained.
If the dongle is present but no numeric counter is found (unconfigured
slot), `query_pin_retries` dies immediately.

| Call site | Max retries | Purpose |
|---|---|---|
| Initial presence check | 1 (+ INPUT retry) | Get first counter, prompt reinsert on failure |
| `show_pin_retries()` | 3 per PIN attempt | Display fresh count before each try |
| `max_attempts` re-read | 1 | Seed attempt ceiling with current value |

```
NK3 (factory):      8 attempts  -> default-PIN skip at < 3, max_attempts = min(retries-1, 3)
NK3 (decremented):  7 attempts  -> max_attempts = 3 (capped)
NK3 (decremented):  2 attempts  -> max_attempts = 1 (min(2-1, 3))
Pre-NK3 (factory):  3 attempts  -> max_attempts = min(3-1, 3) = 2
Pre-NK3 (decrem.):  2 attempts  -> max_attempts = min(2-1, 3) = 1
```

## Pre-NK3 vs NK3 PIN behavior

- **Pre-NK3** (Pro, Storage, Librem Key): Admin PIN counter starts at 3
  (hardware-enforced), maps directly to OATH credential creation PIN.
- **NK3**: Secrets App PIN counter starts at 8 (configurable), protects
  OATH credential operations.

## Firmware version display

`hotpkey_fw_display` in `initrd/etc/functions.sh` parses `hotp_verification info`
output to show the dongle firmware version with color coding.  Minimum-version
thresholds are in `initrd/etc/dongle-versions`.
See [ux-patterns.md](ux-patterns.md#color-coded-version-checks).
