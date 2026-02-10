#!/bin/bash
# Retrieve the sealed file from the NVRAM, unseal it and compute the totp

# shellcheck source=initrd/etc/functions.sh
. /etc/functions.sh

TOTP_SECRET="/tmp/secret/totp.key"

TRACE_FUNC

if [ "$CONFIG_TPM" = "y" ]; then
	# Verify primary handle first so callers can present a clear tamper UI
	if ! tpmr.sh verify-primary >/dev/null 2>&1; then
		rc=$?
		case "$rc" in
			2)
				die "No TPM primary handle. You must reset the TPM to seal secret to TPM NVRAM"
				;;
			3)
				die "TPM primary handle hash mismatch. Possible tampering; aborting unseal"
				;;
			*)
				die "TPM primary handle verification failed (code $rc)"
				;;
		esac
	fi

	DO_WITH_DEBUG --mask-position 5 \
		tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$TOTP_SECRET" || \
		die "Unable to unseal TOTP secret from TPM"
fi

if ! DO_WITH_DEBUG totp -q <"$TOTP_SECRET"; then
	shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
	die 'Unable to compute TOTP hash?'
fi

shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
exit 0
