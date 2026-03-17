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

Use `0 80` for auto-height dialogs:
- Width `80` matches the terminal column count.
- Height `0` lets whiptail compute the required height automatically.

Use explicit heights (e.g. `22 80`) only when the content is known to be a fixed number of lines
and you need to constrain height to avoid a scrollable box.

---

## `INPUT` — inline terminal prompts

`INPUT` (defined in `initrd/etc/functions`) is the standard way to prompt the user for typed
input in non-whiptail contexts (e.g. recovery shell, passphrase entry, confirmation tokens).

```bash
INPUT "prompt text" [read-flags] [VARNAME]

# Examples:
INPUT "Enter new passphrase:" -r -s new_pass
INPUT "Enter TPM owner password:" -r owner_pw
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

### Gate before sealing new secrets

`gate_reseal_with_integrity_report` (`initrd/bin/gui-init`) must be called before any operation
that seals new TPM secrets. It verifies:
1. `/boot` integrity (file hashes)
2. Detached signature (`/boot/kexec.sig`) can be verified against the current keyring

If either check fails, the user is shown an error and the sealing operation is aborted.
This prevents new TOTP/HOTP/DUK secrets from being sealed against a potentially compromised `/boot`.

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
