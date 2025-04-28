# Heads Debug Logging

Heads produces debug logging to aid development and troubleshooting.

Logging is produced in scripts at a _log level_.
Users can set an _output level_ that controls how much output they see on the screen.

# Log Levels

In order from "most verbose" to "least verbose":

LOG > TRACE > DEBUG > INFO > (console) > NOTE > warn

("console" level output is historical and should be replaced with INFO.)

## LOG

LOG is for very detailed output or output with uncontrolled length.
It never goes to the screen, this always goes to the log file.
Usually, we dump outputs of commands like 'lsblk', 'lsusb', 'gpg --list-keys', etc. at LOG level (using DO_WITH_DEBUG or SINK_LOG), so we can tell the state of the system from a log submitted by a user.
We rarely want these on the console as they usually hide more relevant output with information that we already know.

Use this in situations like:
* Dumping information about the state of the system for debugging.  The output doesn't indicate any specific action/decision in Heads or a problem, it's just state relevant for troubleshooting the rest of the log.
* Tracing something that might be very long (including "we don't know how long this will be", even if it's sometimes short).  Very long output isn't useful on the console, since you can't scroll back, and it hides more important information.
* The output is intended for debugging a specific topic, and usually unintersting otherwise.  We want to be able to turn up output to DEBUG/TRACE when working on any topic without excessively filling the console with every topic's detailed output.

## TRACE

TRACE is for following execution flow through Heads.
(TRACE_FUNC logs the current source location at TRACE level, you can use this when entering a function or script, this is much more common than using TRACE directly.)

You can also use TRACE to show parameter values to scripts or functions.
Since TRACE is for execution flow, show the unprocessed parameters as provided by the caller, not an interpreted version.
(This is uncommon though as it is very verbose, and we can also capture interesting call sites with DO_WITH_DEBUG.)

You can invoke TRACE to show specific execution flow when needed, but if you are tracing the result of a decision, consider using DEBUG instead.

Use this in situations like:
* Following control flow - use TRACE_FUNC when entering a script or function
* Showing the parameters used to invoke a script/function, when they are especially relevant and not excessively verbose

## DEBUG

DEBUG is for most log information that is relevant if you are a Heads developer.

Use DEBUG to highlight the decisions made in script logic, and the information that affects those decisions.
Generally, focus on decision points (if, else, case, while, for, etc.), because we can keep following straight-line execution without further tracing.

Decision points usually capture program behavior the best.
Show the information that is about to influence a decision (`DEBUG "Found ${#DEVS[@]} block devices: to check for LUKS:" "${DEVS[@]}"`) and/or the results of the decision (`DEBUG "${DEVS[$i]} is not a LUKS device, ignore it`).

Use DO_WITH_DEBUG to capture a particular command execution to the debug log.
The command and its arguments are captured at DEBUG level (as they usually indicate the decisions the command will make), and the command's stdout/stderr are captured at LOG level.
See DO_WITH_DEBUG for examples of usage.

Use this in situations like:

* Showing information derived or obtained that will influence logical decisions and actions
* Showing the result of decisions and the reasons for them

## INFO

INFO is for contextual information that may be of interest to end users, but that is not required for use of Heads.
Users can control whether this is displayed on the console.

Users might use this to troubleshoot Heads configuration or behavior, but this should not require knowledge of Heads implementation or developer experience.

For example:

* "Why can't I enable USB keyboard support?"  `INFO "Not showing USB keyboard option, USB keyboard is always enabled for this board"`
* "Why isn't Heads booting automatically?"  `INFO "Not booting automatically, automatic boot is disabled in user settings"`
* "Why didn't Heads prompt me for a password?"  `INFO "Password has not been changed, using default"`)

These do not include highly technical details.
They can include configuration values or context, _but_ they should refer to configuration settings using the user-facing names in the configuration menus.

Use this in situations like:

* Showing very high level decision-making information, which is reasonably understandable for users not familiar with Heads implementation
* Explaining a behavior that could reasonably be unexpected for some users

## console

This level is historical, use INFO for this.
It is documented as there are still some occurrences in Heads, usually `echo`, `echo >&2`, or `echo >/dev/console`, each intended to produce output directly on the console.
The intent is the same as INFO.

(This is different from `echo` used to produce output that might be captured by a caller, which is not logging at all.)

Avoid using this, and change existing console output to INFO or another level.

## NOTE

NOTE is for contextual information explaining something that is _likely_ to be unexpected or confusing to users new to Heads.

Unlike INFO, it cannot be hidden.  Use this only if the behavior is likely to be unexpected or confusing to many users.  If it is only possibly unexpected or uncommon that it is confusing, consider INFO instead.

Do not overuse this above INFO.  Adding too much output at NOTE causes users to ignore it, as there is too much output.

For example:

* "Rebooting in 3 seconds to enable booting default boot option".  Users probably don't expect the firmware to reboot to accomplish this behavior, this is unique to Heads.  Without a message justifying the reboot, it would likely appear that the firmware faulted and reset unexpectedly.
* "Your GPG User PIN, followed by Enter key will be required [...]".  GPG prompts are very confusing to users unfamiliar with GPG (which is most users).

## warn

warn is for output that indicates a problem.  We think the user should act on it, but we are able to continue, possibly with degraded functionality.
(This level and the utility function are lowercase, as they predate the other levels.)

This is apppriate when _all_ of the following are true:

- there is a _likely_ problem
- we are able to continue, possibly with degraded functionality
- the warning is _actionable_ - there is a reasonable change that could silence the warning if this is intentional

**Do not overuse this.** Overuse of this level causes user to become accustomed to ignoring warnings.
This level only has value as long as it does not occur frequently, so users will notice warnings.

Warnings must indicate a _likely_ problem.
(Not a rare or remote possibility of a problem.)

Warnings are only appropriate if we're able to continue operating.
If we can't, consider prompting the user instead, since we cannot do what they asked.

Warnings must be _actionable_.  Only warn if there is a reasonable change the user can make to avoid the warning.

For example:
* Warning when using default passphrases that are completely insecure is reasonable - the user has no security, and if they want that, they should use Basic mode.
* Warning when an unknown variable appears in config.user is not reasonable - there's no reasonable way for the user to address this.

# Output Levels

Users can choose one of three output levels for extra console information.

* None - Show no extra output.  Only warnings appear on console.  (Some 'console' level output appears that has not been addressed yet.)
* Info - Show information about operations in Heads.  (INFO and below.)
* Debug - Show detailed information suitable for debugging Heads.  (TRACE and below.)  Log file captures all levels.

TODO: Document what happens for kernel messages too.
This is more complex though since it is influenced by the board's config and user config differently (maybe we should improve that.)

TODO: Document the variables that control these levels

## None - no extra output

| Sink                    | LOG | TRACE | DEBUG | INFO | console | NOTE | warn |
|-------------------------|-----|-------|-------|------|---------|------|------|
| Console (via /dev/kmsg) |     |       |       |      | Yes*    | Yes  | Yes  |
| /tmp/debug.log          | Yes |       |       |      |         |      |      |

* Most 'console' output should be changed to INFO, that content isn't intended to be displayed in quiet mode

No extra output is specified with:

```
CONFIG_DEBUG_OUTPUT=n
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=n
CONFIG_QUIET_MODE=y
```

## Info

| Sink                    | LOG | TRACE | DEBUG | INFO | console | NOTE | warn |
|-------------------------|-----|-------|-------|------|---------|------|------|
| Console (via /dev/kmsg) |     |       |       | Yes  | Yes     | Yes  | Yes  |
| /tmp/debug.log          | Yes |       |       |      |         |      |      |

Info output is enabled with:

```
CONFIG_DEBUG_OUTPUT=n
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=n
CONFIG_QUIET_MODE=n
```

## Debug

| Sink                    | LOG | TRACE | DEBUG | INFO | console | NOTE | warn |
|-------------------------|-----|-------|-------|------|---------|------|------|
| Console (via /dev/kmsg) |     | Yes   | Yes   | Yes  | Yes     | Yes  | Yes  |
| /tmp/debug.log          | Yes | Yes   | Yes   | Yes  | Yes     | Yes  | Yes  |

Debug output is enabled with:

```
CONFIG_DEBUG_OUTPUT=y
CONFIG_ENABLE_FUNCTION_TRACING_OUTPUT=y
CONFIG_QUIET_MODE=n
```
