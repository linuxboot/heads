#!/bin/bash
set -e -o pipefail
. /etc/functions
. /tmp/config

TRACE_FUNC

if pnor "$2" -r HBI > /tmp/pnor.part 2>/dev/null; then
    cbfs "$@" -o /tmp/pnor.part && pnor "$2" -w HBI < /tmp/pnor.part
else
    cbfs "$@"
fi
