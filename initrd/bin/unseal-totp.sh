#!/bin/bash
# Retrieve the sealed file from the NVRAM, unseal it and compute the totp

. /etc/functions.sh

TOTP_SECRET="/tmp/secret/totp.key"

fail_unseal_reset_required() {
	TRACE_FUNC
	# A TPM-side unseal failure generally indicates that reset/re-ownership is
	# required before allowing reseal/generate workflows again.
	set_tpm_reset_required "$*" "unseal-totp.sh:fail_unseal_reset_required"
	DEBUG "fail_unseal_reset_required: reason='$*'"
	fail_unseal "$@"
}

TRACE_FUNC

if [ "$CONFIG_TPM" = "y" ]; then
	if [ "$CONFIG_TPM2_TOOLS" = "y" ]; then
		# if we are talking to TPM2, ensure the primary handle exists; TPM1
		# does not have the concept, so skip the check.
		if [ ! -f "/tmp/secret/primary.handle" ]; then
			fail_unseal_reset_required "Unable to unseal TOTP secret from TPM; no TPM primary handle. Reset the TPM (Options -> TPM/TOTP/HOTP Options -> Reset the TPM in the GUI)." || exit 1
		fi
		# show unseal invocation; there is no secret argument to mask
		if ! DO_WITH_DEBUG \
			tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$TOTP_SECRET"; then
			# A TPM2 unseal failure with primary handle present is commonly a
			# policy/PCR mismatch (for example after firmware updates). Keep this
			# recoverable via reseal and do not force reset-required marker.
			fail_unseal "Unable to unseal TOTP secret from TPM. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal." || exit 1
		fi
	else
		# TPM1 path: after reset/re-ownership, unseal failures here are best
		# handled by resealing the secret from the GUI flow.
		if ! DO_WITH_DEBUG tpmr.sh unseal 4d47 0,1,2,3,4,7 312 "$TOTP_SECRET"; then
			fail_unseal "Unable to unseal TOTP secret from TPM. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal." || exit 1
		fi
	fi
fi

if [ ! -s "$TOTP_SECRET" ]; then
	fail_unseal "Unable to unseal TOTP secret from TPM; secret file $TOTP_SECRET is missing or empty. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal." || exit 1
fi

# Run totp without DO_WITH_DEBUG: stdout is the TOTP code and must not be
# logged (security hazard - code in debug.log could be used to verify OTPs).
# Errors (stderr) are still captured for debugging.
if ! totp -q <"$TOTP_SECRET" 2> >(SINK_LOG "totp stderr"); then
	shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
	fail_unseal 'Unable to compute TOTP hash?' || exit 1
fi

shred -n 10 -z -u "$TOTP_SECRET" 2>/dev/null
exit 0
