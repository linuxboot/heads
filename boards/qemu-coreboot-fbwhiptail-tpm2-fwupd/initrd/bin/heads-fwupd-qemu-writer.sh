#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

# shellcheck source=/dev/null
. /etc/functions.sh

[ -s "$1" ] || DIE "QEMU firmware update payload is empty"
sha256sum "$1" >/tmp/heads-fwupd-qemu-applied.sha256
STATUS_OK "QEMU file-backed firmware writer accepted the update"
