# HOTP & USB Security Dongle

This document covers HOTP token setup, NK3 specifics, and the integration
between `seal-hotpkey.sh` and `hotp_verification`.

See also: [security-model.md](security-model.md), [ux-patterns.md](ux-patterns.md).

---

## HOTP hardware token check (`hotp_verification`)

The HOTP token check uses `hotp_verification` which communicates with the USB
dongle over either HID (Nitrokey Pro, Nitrokey Storage, Librem Key) or CCID
(Nitrokey 3, a.k.a. NK3).  The command `hotp_verification info` queries the
dongle status, firmware version, and PIN retry counters.

### Return codes

Internal codes (from `src/return_codes.h`) and their corresponding exit codes
(converted via `res_to_exit_code()` in `src/return_codes.c`):

| Internal code | Value | Exit code | Meaning |
|---|---|---|---|
| `RET_NO_ERROR` | 23 | 0 | Success |
| (no device) | -- | 1 | No dongle detected at all (`device_connect` failed) |
| `RET_WRONG_PIN` | 4 | 2 | Wrong PIN |
| `RET_COMM_ERROR` | 29 | 3 | CCID communication error e.g. OATH SELECT failed |
| `RET_VALIDATION_FAILED` | 21 | 4 | HOTP code incorrect |
| (unmapped) | -- | 5 | `dev_unknown_command` mapped to exit 5 |
| `RET_SLOT_NOT_PROGRAMMED` | 3 | 6 | Slot not programmed (HID devices) |
| bad format codes | 24-26 | 7 | Badly formatted input |
| `RET_CONNECTION_LOST` | 28 | 8 | Connection lost mid-operation |
| `RET_INVALID_PARAMS` | 27 | 100 | Invalid parameters |

Internal codes without a dedicated `if` in `res_to_exit_code()` fall
through to `EXIT_OTHER_ERROR` (3).  `RET_COMM_ERROR` (29) is technically
in this catch-all group despite being listed above — the table entry
reflects its runtime exit code, not a dedicated handler.
`RET_SECURITY_STATUS_NOT_SATISFIED` (32) and `RET_SLOT_NOT_CONFIGURED`
(33) also fall through.  `RET_NO_PIN_ATTEMPTS` (31) falls through in
general but the `info` handler converts it to `RET_NO_ERROR` before
exit, so `info` exits 0.

| Internal code | Value | `res_to_error_string()` output | Notes |
|---|---|---|---|
| `RET_NO_PIN_ATTEMPTS` | 31 | "Device does not show PIN attempts counter" | Used by `info` for unconfigured NK3 slot |
| `RET_SLOT_NOT_CONFIGURED` | 33 | "HOTP slot is not configured" | Only returned by `check`, not `info` |
| `RET_SECURITY_STATUS_NOT_SATISFIED` | 32 | "Touch was not recognized..." | Not returned by `info` |

### NK3 `info` command: exact output and exit codes

The NK3 communicates over CCID.  The `info` handler in `src/main.c`
calls `device_get_status()` then `check_ret()` which returns early
when the result is neither `RET_NO_ERROR` nor `RET_NO_PIN_ATTEMPTS`.

| Scenario | Exit code | `Connected device status:` printed? | Counter line |
|---|---|---|---|
| Slot configured | 0 | yes | `Secrets app PIN counter: N` (numeric) |
| Slot unconfigured, OATH applet alive (Path A) | 0 | yes | `PIN is not set - set PIN before the first use` |
| OATH applet SELECT fails (Path B) | 3 | no (check_ret returns early) | not printed |
| No dongle connected | 1 | no | not printed |

**Path A** (OATH applet returns 0x9000, no PIN counter TLV):
- `send_select_ccid()` succeeds but `Tag_PINCounter` is absent
- `status_ccid()` returns `RET_NO_PIN_ATTEMPTS` (31)
- `check_ret` allows continuation (31 matches `RET_NO_PIN_ATTEMPTS`)
- Full status is printed; `retry_user` is 0 so the counter line reads
  `"PIN is not set - set PIN before the first use"`
- `parse_cmd_and_run()` converts 31 to `RET_NO_ERROR` -> exit 0

**Path B** (OATH applet SELECT returns non-0x9000 status):
- `send_select_ccid()` returns `data_status_code != 0x9000`
- `status_ccid()` returns `RET_COMM_ERROR` (29)
- `check_ret` returns early -- no "Connected device status:" is printed
- Exit code: 3 (`EXIT_OTHER_ERROR`, 29 not in `res_to_exit_code`)

### NK3 PIN counter mapping

The NK3 exposes two separate PIN systems:

| PIN type | Source | Counter path in `info` output | Factory default |
|---|---|---|---|
| Secrets App PIN | OATH applet (`Tag_PINCounter` TLV in AID `a0 00 00 05 27 21 01`) | `Secrets app PIN counter:` | 8 attempts |
| GPG Admin PIN | PGP applet (ISO 7816 `0xCA` on AID `a0 00 00 08 47 00 00 00 01`) | `GPG Card counters: Admin` | 3 attempts |
| GPG User PIN | PGP applet (same `0xCA` command) | `GPG Card counters: User` | 3 attempts |

The HOTP initialization in `seal-hotpkey.sh` uses the **Secrets App PIN**
(called `admin_pin_retries` for historical reasons) because the Secrets App
PIN protects the OATH credential slot creation.

## seal-hotpkey.sh NK3 handling

`initrd/bin/seal-hotpkey.sh` interacts with `hotp_verification` at several
points:

1. **Initial presence check**: runs `hotp_verification info` and captures
   stdout regardless of exit code, then looks for the string `Connected
   device status:` to confirm the dongle is present.  This distinguishes
   "no dongle" (no such line) from "dongle present but slot unconfigured"
   (line present, exit code may still be non-zero).  If the device is not
   responding, the user is prompted to reinsert the dongle (to reset a
   stalled CCID state) and the check is retried once.

2. **PIN retry extraction** (NK3): greps the output for
   `Secrets app PIN counter:`.  When no slot is configured, the value is
   the string `"PIN is not set - set PIN before the first use"` instead
   of a number.  The script uses `hotp_verification info` output as-is
   -- the counter is the truth and no value is fabricated.

3. **show_pin_retries()**: re-queries `hotp_verification info` and
   parses the counter.  A temp variable (`new_retries`) guards against
   transient re-query failures: when `hotp_verification info` returns
   empty output (e.g. device busy after a wrong PIN), the last known
   counter value is preserved instead of being overwritten.

4. **max_attempts calculation**: re-reads the counter the same way with
   a separate temp variable (`_pin_retries`) and the same transient-failure
   guard.  When the counter is non-numeric (unconfigured slot) the `-ge 2`
   test fails and `max_attempts` falls through to the else clause (3).

## Fixed PIN counter vs configurable

- **Pre-NK3** (Nitrokey Pro, Nitrokey Storage, Librem Key): The Admin PIN
  retry counter always starts at 3 (hardware-enforced).  This maps directly
  to the OATH credential creation PIN.
- **NK3**: The Secrets App PIN retry counter starts at 8 (factory default)
  and is configurable.  This PIN protects OATH credential operations.

## seal-hotpkey.sh PIN retry behavior

```
NK3 (factory):      8 attempts  -> default-PIN skip at < 3, max_attempts = min(retries-1, 3)
NK3 (decremented):  7 attempts  -> max_attempts = 3 (capped)
NK3 (decremented):  2 attempts  -> max_attempts = 1 (min(2-1, 3))
Pre-NK3 (factory):  3 attempts  -> max_attempts = min(3-1, 3) = 2
Pre-NK3 (decrem.):  2 attempts  -> max_attempts = min(2-1, 3) = 1
```

When the counter is non-numeric (slot unconfigured -- "PIN is not set"
string), `max_attempts` falls through to the else clause (3) so the
user is never blocked from sealing.  On transient re-query failures,
the last known counter value is preserved rather than replaced.

## Firmware version display

`hotpkey_fw_display` in `initrd/etc/functions` parses the `hotp_verification
info` output to show the dongle firmware version with color coding:
minimum-version thresholds are defined in `initrd/etc/dongle-versions`.
See [ux-patterns.md](ux-patterns.md#color-coded-version-checks) for details.
