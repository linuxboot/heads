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
				echo "No TPM primary handle. You must reset the TPM to seal secret to TPM NVRAM" >&2
				exit 2
				;;
			3)
				echo "TPM primary handle hash mismatch. Possible tampering; aborting unseal" >&2
				exit 3
				;;
			*)
				echo "TPM primary handle verification failed (code $rc)" >&2
				exit "$rc"
				;;
		esac
	fi

	if ! DO_WITH_DEBUG --mask-position 5 tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$TOTP_SECRET"; then
		echo "Unable to unseal TOTP secret from TPM" >&2
		exit 1
	fi
fi

if ! DO_WITH_DEBUG totp -q <"$TOTP_SECRET"; then
	shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
	echo 'Unable to compute TOTP hash?' >&2
	exit 4
fi

shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
exit 0
