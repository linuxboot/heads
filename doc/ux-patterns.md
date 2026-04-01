# Heads UX Patterns

This document describes the coding conventions for interactive UX in Heads initrd scripts.
See also: [logging.md](logging.md) for console/log output levels, and the
[Heads architecture reference](https://deepwiki.com/linuxboot/heads) for validated system context.

---

## Whiptail dialogs

All interactive dialogs use `whiptail` through one of three wrapper functions defined in
`initrd/etc/gui_functions`:

| Wrapper | Background color | When to use |
|---|---|---|
| `whiptail_error` | Red | Errors, security warnings, irreversible states |
| `whiptail_warning` | Yellow/amber | Cautionary prompts, confirmations before risky actions |
| `whiptail_type $BG_COLOR` | Caller-supplied color | Normal menus, informational dialogs |

**Never call `whiptail` directly** from initrd scripts — always go through a wrapper.
The wrappers handle color selection for both `fbwhiptail` (framebuffer) and `newt` (text) backends.

### Message folding — centralized in `_whiptail_preprocess_args`

`_whiptail_preprocess_args` in `initrd/etc/gui_functions` is the **single place** responsible
for expanding `\n` escape sequences and word-wrapping message text at 76 columns:

```bash
_WHIPTAIL_ARGS+=("$(printf '%b' "$_arg" | fold -s -w 76)")
```

This runs automatically on the message argument (the string immediately after `--msgbox`,
`--yesno`, `--menu`, etc.) before it is passed to `whiptail`.

**Callers must not pre-fold.** Pass raw strings with `\n` escape sequences directly to the
wrapper functions — `_whiptail_preprocess_args` handles everything:

```bash
# CORRECT — raw string, \n escapes, no fold
whiptail_error --title 'ERROR' \
    --msgbox "Something failed.\n\nDetails here.\n\nChoose an action:" 0 80

# WRONG — double-folding, redundant pipe
local msg
msg="$(printf '%b' "Something failed.\n\nDetails here." | fold -s -w 76)"
whiptail_error --title 'ERROR' --msgbox "$msg" 0 80
```

The 76-column wrap width leaves 2 columns of padding inside a standard 80-column dialog,
preventing text from being cut off at the dialog border.

### Dialog structure

Whiptail messages typically follow this layout:

```
<Short header line>

<One or two sentences of context explaining the situation>

<Guidance or question: "Choose an action:" / "Would you like to...?">
```

Keep the first paragraph short — it appears at the top of the box where vertical space is limited
and it must not wrap onto a third line at 76 columns.
The guidance paragraph is always the last line so it sits adjacent to the menu items or OK button.

### Window sizing

**fbwhiptail (framebuffer backend)** ignores height and width arguments
entirely — it always auto-sizes from content using its own internal layout
constants.  Any values passed are silently discarded.

**newt (text backend)** uses the height and width arguments:

- `0` height triggers `guessSize()`, which computes the minimum height from
  content.  Use `0` for height in all dialogs.
- `0` width also triggers `guessSize()` for width — the dialog expands to fit
  the longest content line.  **Use `0` width only for dialogs that contain
  dynamic strings of unpredictable length** (e.g. ROM filenames, file paths).
- For dialogs with static text, use a fixed width (typically `80`).  This
  produces a stable, readable layout in newt and is a no-op in fbwhiptail.

In practice:

```bash
# Dynamic content (ROM filename, file path) — width must fit at runtime:
whiptail_warning --title 'Flash ROM?' \
    --yesno "This will replace your current ROM with:\n\n$PKG_FILE_DISPLAY\n\nDo you want to proceed?" 0 0

# Static text — fixed width; fbwhiptail ignores it, newt uses it:
whiptail_error --title 'ERROR' \
    --msgbox "This device does not have a TPM.\n\nPress OK to return to the Main Menu" 0 80
```

---

## `INPUT` — inline terminal prompts

`INPUT` (defined in `initrd/etc/functions`) is the standard way to prompt the user for typed
input in non-whiptail contexts (e.g. recovery shell, passphrase entry, confirmation tokens).

```bash
INPUT "prompt text" [read-flags] [VARNAME]

# Examples:
INPUT "Enter new passphrase:" -r -s new_pass
INPUT "Enter TPM owner passphrase:" -r owner_pw
INPUT "Press Enter to continue" -r _ignored
```

**Cursor placement**: The prompt is printed with a trailing space and no newline (`printf '...' "$prompt"`).
The cursor lands on the same line as the prompt — the user types immediately after it.
Do not add `\n` or `echo` between the prompt and the `read`.

**Device routing**: When `HEADS_TTY` is set (gui-init context after `cttyhack`), both prompt
output and `read` use that device — bypassing any stdout/stderr redirections the caller may have.
When `HEADS_TTY` is unset, the prompt goes to stderr and `read` uses stdin (serial recovery shell
convention).

**Do not use INPUT for yes/no choices** — use `whiptail_warning --yesno` or
`whiptail_error --yesno` for those so the user has a clear graphical dialog.

### Surviving a screen repaint — acknowledgment pattern

`WARN`/`NOTE`/`STATUS` write to the terminal but do not block. When control
returns to a caller that repaints the screen (whiptail menu, gui-init loop),
those messages are immediately overwritten and the user never sees them.

For security-critical notices that **must** be read, follow the logging call
with an `INPUT` acknowledgment:

```bash
WARN "Default Admin PIN detected - your dongle is using factory defaults."
INPUT "Change secrets via Options > OEM Factory Reset / Re-Ownership. Press Enter to acknowledge." ignored
```

The `INPUT` call blocks until Enter is pressed, keeping the warning on screen
regardless of what the caller does next.

---

## Security UX — integrity report and unknown keys

### UNKNOWN_KEY / untrusted-key scenario

When `/boot/kexec.sig` is signed by a key that is present in the GPG keyring but is **not** the
key that matches the currently inserted OpenPGP smartcard, the system cannot verify content integrity.

The correct UX is:

- **State clearly that /boot cannot be trusted** — do not frame this as merely "signed by a different key."
- **Do not offer re-signing as the primary action** — knowing the fingerprint, owner, and date of
  the previous key is NOT sufficient to trust content. Re-signing would legitimize unknown changes.
- **Guide toward backup restoration or OEM Factory Reset** as the safe recovery path.
- **Re-signing is only valid** if the user can independently verify that the content of /boot is
  exactly what they expected through an out-of-band means (e.g. comparing against a known-good
  clean OS installation, not against the signature itself).

### Show the actual diagnostic — do not paraphrase

When an internal check fails and a reason is already available as a string,
show it directly to the user. Do **not** grep the message and replace it with
a vague summary — that discards the specific detail the user needs to act.

```bash
# CORRECT — user sees exactly which counter and why
preflight_reason="${preflight_error_msg%%. Reset TPM from GUI*}"

# WRONG — throws away counter ID and specific condition
if echo "$preflight_error_msg" | grep -qi "cannot be read"; then
    preflight_reason="Stored TPM rollback metadata cannot be read."
fi
```

Strip action guidance from the displayed reason only when the menu already
offers those actions — this avoids duplication, not information loss.

### Gate before sealing new secrets

`gate_reseal_with_integrity_report` (`initrd/bin/gui-init`) must be called before any operation
that seals new TPM secrets. It verifies:
1. `/boot` integrity (file hashes)
2. Detached signature (`/boot/kexec.sig`) can be verified against the current keyring

If either check fails, the user is shown an error and the sealing operation is aborted.
This prevents new TOTP/HOTP/DUK secrets from being sealed against a potentially compromised `/boot`.

---

## GPG User PIN caching

Heads signs `/boot` content using a GPG key. For OpenPGP smartcard keys, the
card's "force signature PIN" property (enabled by default on supported tokens)
requires the User PIN to be presented to the card for every signing operation.
Without caching, the user would be prompted on every `gpg --detach-sign` call
within the same session.

To reduce PIN prompts (issue [#1955](https://github.com/linuxboot/heads/issues/1955)),
Heads caches the validated PIN for the session in `/tmp/secret/gpg_pin`
(mode 600, on tmpfs; cleared at power-off).

### Architecture: loopback mode

All GPG signing in Heads uses `--pinentry-mode=loopback` with
`--passphrase-file /tmp/secret/gpg_pin`. This means gpg-agent never calls
`pinentry` for signing operations — the PIN is supplied directly from the
cache file through the loopback channel. `initrd/.gnupg/gpg-agent.conf`
sets `allow-loopback-pinentry` to permit this.

`confirm_gpg_card` in `initrd/etc/functions` is a thin wrapper around
`cache_gpg_signing_pin`, which implements both key paths below.

### Priming the cache: test-sign in cache_gpg_signing_pin

Both key paths prime the PIN cache **inside `cache_gpg_signing_pin`** (called
via `confirm_gpg_card`) via a validated test-sign before returning. The cache
is always populated before `kexec-sign-config` performs the actual signing.
On second and later calls in the same session, `[ -s /tmp/secret/gpg_pin ]`
triggers an early return with no prompting.

**Smartcard (User PIN) path:**
`cache_gpg_signing_pin` reads the card status to display PIN retry counters,
then collects the User PIN via `INPUT` (Heads-controlled prompt). It performs
a test detach-sign using `--pinentry-mode=loopback --passphrase-file
<(printf '%s' "$sc_user_pin")` and verifies the signature. On success the PIN
is written to `/tmp/secret/gpg_pin` and `STATUS_OK "GPG User PIN cached for
this session"` is emitted. On bad PIN: clear input, WARN with updated retry
counter, retry (up to 3 attempts). The test-sign nonce is shredded on
completion.

**Backup key (Admin PIN) path:**
`cache_gpg_signing_pin` collects the Admin PIN via `INPUT`, imports the
private subkeys with `--pinentry-mode=loopback --passphrase-file`, does a
test-sign with loopback, verifies the signature, then writes the validated
passphrase directly to `/tmp/secret/gpg_pin` and emits
`STATUS_OK "GPG Admin PIN cached for this session"`.

### Bad PIN handling

On bad-PIN signing failure inside `kexec-sign-config` or `gpg_auth`, callers
delete `/tmp/secret/gpg_pin` before retrying. The next call to `confirm_gpg_card`
finds an empty cache, runs the full test-sign flow, and re-prompts the user.

### STATUS_OK on cache save

`cache_gpg_signing_pin` emits `STATUS_OK` when the PIN is successfully cached:

- Smartcard path: `STATUS_OK "GPG User PIN cached for this session"`
- Backup key path: `STATUS_OK "GPG Admin PIN cached for this session"`

---

## Once-per-session display

Some informational displays are useful on first occurrence but become noise if
repeated across multiple call sites in the same session. Guard these with a
session flag file under `/tmp`:

```bash
some_display_function() {
    [ -f /tmp/some_shown ] && return
    # ... produce the display ...
    touch /tmp/some_shown
}
```

`/tmp` is on tmpfs and is cleared at reboot, so the guard is automatically
lifted on the next boot. No cleanup code is needed.

This pattern is used by `hotpkey_fw_display` in `initrd/etc/functions` to show
the USB security dongle firmware version at most once per session, regardless
of how many times the function is called from different code paths.

### Color-coded version checks

When displaying a version that has a known minimum, use the logging level that
matches the severity — do not embed raw ANSI codes in STATUS or produce two
separate messages for the same device:

| Device | Condition | Function | Visual result |
| --- | --- | --- | --- |
| NK3 / Nitrokey Pro / Pro 2 | `fw_ver >= min_ver` | `STATUS_OK` | Bold green — firmware is current |
| NK3 / Nitrokey Pro / Pro 2 | `fw_ver < min_ver`, nitropy upgrade available | `NOTE` with inline `\033[1;33m` on the version | Yellow version — upgrade recommended |
| Nitrokey Pro / Pro 2 | `fw_ver < HOTPKEY_EXTERNAL_REPROGRAM_BELOW` | `NOTE` with inline `\033[1;31m` on the version | Red version — external programmer required |
| Nitrokey Storage | (any version) | `STATUS_OK` | Version shown; no min-ver comparison (Storage min ver TBD) |
| Librem Key | (any version) | `NOTE` | Version shown with advisory to contact Purism — never self-upgradeable |

One message per device, color determined by the worst applicable condition.

#### Nitrokey Pro / Pro 2 external-reprogram threshold

`HOTPKEY_EXTERNAL_REPROGRAM_BELOW="v0.11"` in `initrd/etc/dongle-versions`. Firmware
v0.10 and earlier have no DFU bootloader and cannot be upgraded via nitropy;
the bootloader was introduced in v0.11
([Nitrokey Pro firmware issue #95](https://github.com/Nitrokey/nitrokey-pro-firmware/issues/95)).
The physical hardware is unchanged — this is a firmware-only gap. Devices at
v0.10 or older continue to work normally; the red indicator informs the user
that an external programmer (e.g. SWD/JTAG) is required to flash firmware
up to the minimum recommended version.

This threshold applies to Nitrokey Pro / Pro 2 only. Librem Key is never
self-upgradeable regardless of firmware version (always shown as NOTE
directing users to contact Purism support). Nitrokey Storage has a separate
firmware codebase and is not subject to this threshold.

#### Parsing hotp_verification output

`hotp_verification info` tab-indents all output lines (`\tFirmware: v0.15`).
Use `grep "Firmware:"` without `^` — the `^` anchor would never match a
tab-prefixed line. Also normalize `fw_ver` to add a `v` prefix if absent so
`sort -V` comparisons against the `v`-prefixed threshold values in
`dongle-versions` are consistent.

---

## TPM counter patterns

### Reading counters

`read_tpm_counter` in `initrd/etc/functions` reads a TPM NV counter by index and writes the
output to `/tmp/counter-<id>`. The format is `<hex_index>: <hex_value>`.

**Pipeline exit status**: Never pipe `tpmr counter_read` through `tee` with `|| die` — the
`||` checks the exit status of `tee` (always 0), not `tpmr`. Use a direct redirect:

```bash
# CORRECT — exit status of tpmr is captured
tpmr counter_read -ix "$counter_id" >/tmp/counter-"$counter_id" || die "..."

# WRONG — || die checks tee's exit (always 0), tpmr failure is silent
tpmr counter_read -ix "$counter_id" | tee /tmp/counter-"$counter_id" >/dev/null || die "..."
```

### Counter reads in tpmr

`tpm2_counter_read` and `tpm2_counter_inc` must propagate `tpm2 nvread` failure. Use a local
variable and explicit `|| return 1`:

```bash
# CORRECT
local hex_val
hex_val="$(tpm2 nvread 0x"$index" | xxd -pc8)" || return 1
echo "$index: $hex_val"

# WRONG — echo always exits 0; partial/empty hex is silently written
echo "$index: $(tpm2 nvread 0x$index | xxd -pc8)"
```

---

## `HEADS_TTY` — terminal device routing

`HEADS_TTY` is exported by `gui-init` and `gui-init-basic` after `cttyhack` sets up the
controlling terminal. It holds the path to the actual interactive terminal (e.g. `/dev/tty1`
or `/dev/ttyS0`).

Scripts that output prompts or read interactive input should use `HEADS_TTY` when set:

```bash
if [ -n "$HEADS_TTY" ]; then
    printf '...' >"$HEADS_TTY"
    read "$@" <"$HEADS_TTY"
else
    printf '...' >&2
    read "$@"
fi
```

This ensures prompt/read always use the correct device regardless of how the caller has
redirected stdout/stderr (e.g. `2>/tmp/whiptail`).
