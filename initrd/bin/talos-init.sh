#!/bin/sh
# BMC on Talos must be informed that OS has been started in order to enable fan
# control. This is done by writing 0xFE to I/O ports 0x81 and 0x82 (in that
# order) through LPC connected to first CPU. LPC I/O space of first CPU is
# mapped to memory at 0x80060300D0010000, I/O port number has to be added to
# this address. Write can be performed using busybox's devmem applet.

devmem 0x80060300D0010081 8 254
devmem 0x80060300D0010082 8 254

# Disable fast-reset which doesn't reset TPM and results in different values of
# PRCs every time.
nvram -p ibm,skiboot --update-config fast-reset=0

# Proceed with standard init path
exec /bin/gui-init
