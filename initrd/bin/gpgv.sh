#!/bin/bash
# if we are using the full GPG we need a wrapper for the gpgv executable
# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TRACE_FUNC
exec gpg --verify "$@"
