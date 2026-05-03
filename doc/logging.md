# Heads Debug Logging

Heads produces debug logging to aid development and troubleshooting.

Logging is produced in scripts at a _log level_.
Users can set an _output level_ that controls how much output they see on the **screen**.

**`/tmp/debug.log` always captures every log level regardless of output mode.**
This makes it a complete diagnostic artifact that can be shared with developers after any issue,
without requiring the user to reproduce the problem in debug mode first.
Console visibility is what varies by mode - the log file never loses information.

**`/tmp/measuring_trace.log` captures INFO-level output emitted by `INFO()`, including in Quiet mode.**
This file isolates TPM measurements, sealing operations, and other security-critical
audit trails from the general debug noise. It is written to by the `INFO()` function
alongside `/tmp/debug.log` (both files receive the same INFO output regardless of console output mode).
Use this file when you need to audit Heads' security operations without wading
through all DEBUG/TRACE output.

## Log Levels

In order from "most verbose" to "least verbose":

LOG > TRACE > DEBUG > INFO > STATUS / STATUS_OK > NOTE > WARN > DIE

("console" level output is historical and should be replaced with INFO or STATUS.)

## LOG

LOG is for very detailed output or output with uncontrolled length.
It never goes to the screen. It always goes to debug.log.
Usually, we dump outputs of commands like `lsblk`, `lsusb`, `gpg --list-keys`, etc. at LOG level
(using `DO_WITH_DEBUG` or `SINK_LOG`), so we can tell the state of the system from a log submitted
by a user. We rarely want these on the console as they usually hide more relevant output.

Use this in situations like:

* Dumping information about the state of the system for debugging. The output doesn't indicate any
  specific action/decision in Heads or a problem - it's just state relevant for troubleshooting.
* Tracing something that might be very long. Very long output isn't useful on the console since you
  can't scroll back, and it hides more important information.
* Output intended for debugging a specific topic that is usually uninteresting otherwise.

## TRACE

TRACE is for following execution flow through Heads.
(`TRACE_FUNC` logs the current source location at TRACE level. Use this when entering a function
or script - this is much more common than using TRACE directly.)

You can also use TRACE to show parameter values to scripts or functions.
Since TRACE is for execution flow, show the unprocessed parameters as provided by the caller, not
an interpreted version. (This is uncommon as it is very verbose; we can also capture interesting
call sites with `DO_WITH_DEBUG`.)

If you are tracing the result of a decision, consider using DEBUG instead.

### Reading TRACE_FUNC output

Each TRACE_FUNC call emits the full call chain leading to the current function.
The format is:

```text
TRACE: caller(file:line) -> ... -> current_func(file:line)
```

The line number in each entry means something different depending on position:

* **Non-last entries**: the line number is the **call site** - the line within that function where
  it called the next function in the chain.
* **Last entry**: the line number is where **TRACE_FUNC itself** is called inside the current
  function (typically the first line of the function body).

Example - a `tpmr unseal` call triggered from `gui-init`:

```text
TRACE: main(/init:0) -> main(/bin/gui-init:0) -> main(/bin/tpmr:0) -> main(/bin/tpmr:1037) -> tpm2_unseal(/bin/tpmr:635)
```

* `main(/init:0)` - `/init` is the root script; `:0` marks a cross-process boundary
* `main(/bin/gui-init:0)` - `gui-init` was launched by `/init` as a subprocess
* `main(/bin/tpmr:0)` - `tpmr` was launched by `gui-init` as a subprocess
* `main(/bin/tpmr:1037)` - line 1037 in `tpmr`'s `main` is the call site of `tpm2_unseal "$@"`
* `tpm2_unseal(/bin/tpmr:635)` - line 635 is where `TRACE_FUNC` is in `tpm2_unseal`

Use this in situations like:

* Following control flow - use TRACE_FUNC when entering a script or function
* Showing the parameters used to invoke a script/function, when especially relevant

## DEBUG

DEBUG is for most log information that is relevant if you are a Heads developer.

Use DEBUG to highlight the decisions made in script logic, and the information that affects those
decisions. Generally, focus on decision points (if, else, case, while, for, etc.), because we can
keep following straight-line execution without further tracing.

Show the information that is about to influence a decision and/or the results of the decision.

Use `DO_WITH_DEBUG` to capture a particular command execution to the debug log.
The command and its arguments are captured at DEBUG level (as they usually indicate the decisions
the command will make), and the command's stdout/stderr are captured at LOG level.

Use this in situations like:

* Showing information derived or obtained that will influence logical decisions and actions
* Showing the result of decisions and the reasons for them

## INFO

INFO is for technical/security operations that advanced users want to see.

INFO always goes to debug.log. It is shown on the console in **info** mode via `/dev/console`,
routed via `/dev/kmsg` in **debug** mode (so on-console visibility depends on kernel console settings),
and suppressed from the console in **quiet** mode (where the log file serves as the post-mortem record).

INFO is for operations that:
- Are technically detailed (TPM PCR extends, key generation, cryptographic operations)
- Advanced users want to see when troubleshooting
- Are NOT hand-off guidance (use NOTE for that)
- Are NOT developer-facing logic tracing (use DEBUG for that)

For example:

* `INFO "TPM: Extending PCR[4] with string 'text' (hash: abc123...)"` — string extend
* `INFO "TPM: Extending PCR[4] with content of /path/file (hash: abc123...)"` — file content extend
* `INFO "Measuring /boot/vmlinuz into TPM PCR[4]"` — integrity measurement start
* `INFO "TPM: PCR[4] after extend: 0x..."` — PCR state after extend
* `STATUS "Measuring TPM Disk Unlock Key (DUK) into PCR[6]"` — action announcement (PCR[6] for LUKS sealing)

Do NOT use INFO for:

* User guidance or hand-off instructions — use **NOTE** (sleeps 3s, italic white, cannot be hidden)
* High-level user-facing explanations — use **NOTE** or **STATUS**
* Developer-facing logic/decisions — use **DEBUG**

Use this in situations like:

* Reporting technical security operations (TPM extends, measurements, sealing)
* Showing advanced configuration values that power users care about
* Operations that belong in debug.log and info-mode console for audit/diagnostic purposes

## console

This level is historical, use INFO or STATUS for this.
It is documented as there are still some occurrences in Heads, usually `echo`, `echo >&2`, or
`echo >/dev/console`, each intended to produce output directly on the console.

(This is different from `echo` used to produce output that might be captured by a caller, which is
not logging at all.)

Avoid using this, and change existing console output to INFO, STATUS, or another appropriate level.

## STATUS

STATUS is for action announcements - operations that are starting or in progress - that all users
must see regardless of output mode.

A STATUS message typically precedes STATUS_OK, WARN, or DIE: it announces the start of something
that has an outcome (success, actionable problem, or fatal error). If there is no outcome to report, consider INFO instead.

Use STATUS when an action is beginning or underway:

* "Verifying ISO" - a signature check is running (→ STATUS_OK or DIE follows)
* "Unlocking LUKS device(s) using the Disk Recovery Key passphrase" - an unlock is in progress (→ STATUS_OK or WARN follows)
* "Executing default boot for $name" - what is about to boot (→ WARN or DIE on failure)
* "GPG User PIN retries remaining: N" - state shown before an operation that will consume a PIN attempt

Do NOT use STATUS for descriptions of what will happen based on a user's configuration choice
("Master key will be generated in memory") — use INFO for those.

Unlike INFO, STATUS is always visible on the console in all output modes.
Unlike NOTE, STATUS does not sleep - it is for routine progress announcements.

STATUS always goes to debug.log.

## STATUS_OK

STATUS_OK is for confirmed successful results - use it when reporting that an operation succeeded,
a verification passed, or a resource was confirmed available.

Use STATUS_OK (not STATUS) for completed positive outcomes:

* "ISO signature verified" - verification succeeded
* "LUKS device unlocked successfully" - unlock confirmed
* "GPG signature on kexec boot params verified" - integrity check passed
* "Heads firmware job done - starting your OS" - handoff complete

STATUS_OK uses two signals so success is scannable without relying on either alone:

* **`OK` text prefix** — readable in monochrome, on serial consoles, and with color vision deficiency
* **Bold green color** — instant visual scan for sighted users

This follows the Linux/systemd `[OK]`/`[FAILED]` convention: always pair color with a text label.
The console renders `OK message` (with a leading space) in bold green; debug.log records it in plain text.

## NOTE

NOTE is for **user guidance that needs attention** — it sleeps 3 seconds and prints
blank lines before/after so users cannot scroll past it unread.

NOTE uses **italic white** (`\033[3;37m`) and cannot be hidden from console in any output mode.

Use NOTE for two specific patterns:

**Security reminders** — advice about consequences or risks the user should not overlook,
but that do not indicate a current problem:

* "Please keep your GPG key material backup thumb drive safe"
* "Subkeys will NOT be copied to USB Security dongle"

**Hand-off to uncontrolled output** — when Heads is about to hand control to a tool it does not
own (gpg, cryptsetup, lvm, hardware firmware), and the user will interact directly with that
tool's prompts or output rather than Heads-formatted messages:

* "GPG User PIN required at next smartcard prompt" - the user will type into gpg's own PIN prompt
* "Nitrokey 3 requires physical presence: touch the dongle when prompted" - hardware-level event
* "Please authenticate with OpenPGP smartcard/backup media" - gpg auth flow follows

**Questionnaire/setup guidance** — when walking users through configuration steps:

* "The following questionnaire will help you configure the security components of your system"
* "Each prompt requires a single letter answer (Y/n)"
* "Master key and subkeys will be generated in memory and backed up to a dedicated LUKS container"

For example:

* "Proceeding with unsigned ISO boot" - booting without a verified signature is unexpected and
  carries risk; the user needs to know it is happening deliberately.
* "TOTP secret no longer accessible: TPM secrets were wiped" - mid-session secret loss requires
  immediate user attention.

Unlike INFO (technical operations for advanced users), NOTE is for **user-facing guidance**
that requires the user's attention and cannot be hidden.

Do not overuse this above INFO. Adding too much output at NOTE causes users to ignore it.

## WARN

WARN is for output that indicates a problem. We think the user should act on it, but we are able
to continue, possibly with degraded functionality.

This is appropriate when _all_ of the following are true:
* there is a _likely_ problem
* we are able to continue, possibly with degraded functionality
* the warning is _actionable_ - there is a reasonable change that could silence the warning

**Do not overuse this.** Overuse of this level causes users to become accustomed to ignoring
warnings. This level only has value as long as it does not occur frequently.

Warnings must indicate a _likely_ problem (not a rare or remote possibility).
Warnings are only appropriate if we are able to continue operating.
Warnings must be _actionable_ - only WARN if there is a reasonable change the user can make.

WARN always goes to debug.log.

**WARN sleeps 1 second** and prints blank lines before/after (like NOTE) so users
cannot scroll past it unread. WARN uses **bold yellow** (`\033[1;33m`).

For example:

* Warning when using default passphrases that are completely insecure is reasonable.
* Warning when an unknown variable appears in config.user is not reasonable - there's no reasonable
  way for the user to address this.

## DIE

DIE is for fatal errors from which Heads cannot recover. Execution stops after DIE.

DIE always goes to debug.log and is always shown on the console regardless of output mode.

## INPUT

INPUT is a direct replacement for the `echo "prompt"; read [flags] VAR` pattern.
It displays the prompt in **bold white** to visually distinguish interactive input requests from
progress/info messages.

Usage: `INPUT "prompt text" [read-flags] [VARNAME]`

```bash
# Instead of:
echo "Enter passphrase:"
read -r -s passphrase

# Use:
INPUT "Enter passphrase:" -r -s passphrase
```

The prompt text and `INPUT:` label are always recorded in debug.log for tracing.
All read flags (`-r`, `-s`, `-n N`, etc.) and the variable name are passed through unchanged to `read`.

INPUT displays the prompt with a trailing space and no newline, so the cursor lands immediately
after the prompt text on the same line — the user types on the same line, never on the next line.
A blank line is printed after the user's input to separate it from subsequent output.

Do NOT use INPUT for yes/no confirmation dialogs inside whiptail GUI flows — use whiptail for those.
INPUT is appropriate for inline `[Y/n]` confirmations in terminal-mode scripts (recovery shell,
setup wizards, debug paths) where a full whiptail dialog would be out of place.

## Output Levels

Users can choose one of three output levels for console information.
**`/tmp/debug.log` always captures all levels regardless of the chosen output level.**
**`/tmp/measuring_trace.log` captures INFO-level output emitted by `INFO()` in all modes (including Quiet).**

* **Quiet** - Minimal console output. STATUS, NOTE, WARN and DIE always appear. INFO is suppressed on console.
  `INFO()` output is still captured in `/tmp/debug.log` and `/tmp/measuring_trace.log` for post-mortem analysis.
  Use this for production/unattended systems where the log file is the post-mortem record.
* **Info** - Show information about operations in Heads. INFO and above appear on console.
  INFO also goes to `/tmp/measuring_trace.log` for audit trails.
  Use this for interactive use where the user is watching the screen.
* **Debug** - Show detailed information suitable for debugging Heads. TRACE and DEBUG also appear
  on console. INFO goes to `/tmp/measuring_trace.log` and `/dev/kmsg`.
  Use this when actively developing or diagnosing Heads.

Console output styling - chosen for accessibility across color-deficiency types (WCAG 1.4.1:
color is never the sole signal; text prefixes carry meaning independently):

| Level     | Style        | ANSI code    | Sleep | Blank lines | Quiet mode | Purpose |
|-----------|--------------|--------------|-------|-------------|------------|---------|
| DIE       | bold red     | `\033[1;31m` | 0s    | Yes         | Visible    | Fatal errors - execution stops |
| WARN      | bold yellow  | `\033[1;33m` | 1s    | Yes         | Visible    | Actionable problems - degraded operation |
| NOTE      | italic white | `\033[3;37m` | 3s    | Yes         | Visible    | User guidance needing attention |
| STATUS    | bold only    | `\033[1m`    | 0s    | No          | Visible    | In-progress action announcements |
| STATUS_OK | bold green   | `\033[1;32m` | 0s    | No          | Visible    | Confirmed success outcomes |
| INFO      | green        | `\033[0;32m` | 0s    | No          | Suppressed | Technical operations for advanced users |
| INPUT     | bold white   | `\033[1;37m` | 0s    | No*         | Visible    | Interactive input prompts |

\* INPUT prints a newline after user input, not before.

debug.log and /dev/kmsg always receive plain text without ANSI codes.

All console output goes to **`/dev/console`** — the kernel console device, which follows
the `console=` kernel parameter and reaches whatever output the system was configured for
(serial port, framebuffer, BMC console, etc.) without requiring any process setup.
This means callers never need to care about redirections: a caller that does
`2>/tmp/whiptail` or `>/boot/kexec_tree.txt` will not accidentally capture log output.
Similarly, scripts that use stdout for a structured protocol can safely call STATUS,
STATUS_OK, and any other logging function — log output never appears on stdout.

NOTE (3s), WARN (1s), and DIE (0s) print blank lines before and after the message
so they stand out visually from surrounding output.
STATUS and STATUS_OK do **not** — they are called frequently and blank
lines would make output very noisy.
INPUT displays the prompt inline (no leading blank line); the cursor stays on the same line as the prompt.
A blank line is printed after the user's input to separate it from subsequent output.

### None / Quiet - minimal console output

| Sink                     | LOG | TRACE | DEBUG | INFO | STATUS | STATUS_OK | NOTE | WARN | DIE |
|--------------------------|-----|-------|-------|------|--------|-----------|------|------|-----|
| Console                  |     |       |       |      | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/debug.log          | Yes | Yes   | Yes   | Yes  | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/measuring_trace.log |     |       |       | Yes  |        |           |      |      |     |

In Quiet mode, INFO-level output is suppressed on console but still captured in both log files.

Quiet output is specified with:

```text
CONFIG_DEBUG_OUTPUT=n
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=n
CONFIG_QUIET_MODE=y
```

### Info

| Sink                     | LOG | TRACE | DEBUG | INFO | STATUS | STATUS_OK | NOTE | WARN | DIE |
|--------------------------|-----|-------|-------|------|--------|-----------|------|------|-----|
| Console                  |     |       |       | Yes  | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/debug.log          | Yes | Yes   | Yes   | Yes  | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/measuring_trace.log |     |       |       | Yes  |        |           |      |      |     |

In Info mode, INFO appears on console and is captured in both log files.

Info output is enabled with:

```text
CONFIG_DEBUG_OUTPUT=n
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=n
CONFIG_QUIET_MODE=n
```

### Debug

| Sink                     | LOG | TRACE | DEBUG | INFO | STATUS | STATUS_OK | NOTE | WARN | DIE |
|--------------------------|-----|-------|-------|------|--------|-----------|------|------|-----|
| Console                  |     | Yes*  | Yes   | [**] | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/debug.log          | Yes | Yes   | Yes   | Yes  | Yes    | Yes       | Yes  | Yes  | Yes |
| /tmp/measuring_trace.log |     |       |       | Yes  |        |           |      |      |     |

In Debug mode, INFO goes to `/tmp/measuring_trace.log` and `/dev/kmsg` (not `/dev/console`).
On-console visibility depends on kernel `printk` settings forwarding kmsg to the console.
\* TRACE requires `CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=y` (set automatically with Debug mode).

[**] INFO in Debug mode routes through `/dev/kmsg` (not `/dev/console`); on-console visibility depends on kernel `printk` settings forwarding kmsg to the console.

Debug output is enabled with:

```text
CONFIG_DEBUG_OUTPUT=y
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=y
CONFIG_QUIET_MODE=n
```
