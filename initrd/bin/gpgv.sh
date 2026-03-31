#!/bin/bash
# if we are using the full GPG we need a wrapper for the gpgv executable
. /etc/functions.sh

TRACE_FUNC
exec gpg --verify "$@"
