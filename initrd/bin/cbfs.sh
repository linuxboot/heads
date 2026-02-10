#!/bin/bash
set -e -o pipefail
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh
# /tmp/config is generated at runtime and cannot be followed by shellcheck
# shellcheck disable=SC1091
. /tmp/config

TRACE_FUNC

if pnor "$2" -r HBI > /tmp/pnor.part 2>/dev/null; then
    cbfs "$@" -o /tmp/pnor.part && pnor "$2" -w HBI < /tmp/pnor.part
else
    cbfs "$@"
fi
