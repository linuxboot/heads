#!/bin/bash
. /etc/functions.sh

NOTE "This will erase all keys and secrets from the TPM"

prompt_new_owner_password

tpmr.sh reset "$tpm_owner_passphrase"

# TODO: move the TPM reset + full reprovision flow (counter creation, /boot
# signing, TOTP/HOTP generation, DUK reseal) from gui-init.sh's reset_tpm()
# into a reusable function in functions.sh.  Then tpm-reset.sh and the GUI
# reset_tpm() can both call the same code, eliminating the inconsistency
# between CLI and GUI reset paths.

NOTE "TPM cleared. The TPM rollback counter was destroyed. /boot/kexec_rollback.txt still references the old counter."
NOTE "Restore full functionality from the GUI: Options -> TPM/TOTP/HOTP Options -> Reset the TPM"
