#!/bin/bash
# TPM Wrapper - to unify tpm and tpm2 subcommands

. /etc/functions.sh

SECRET_DIR="/tmp/secret"
PRIMARY_HANDLE="0x81000000"
ENC_SESSION_FILE="$SECRET_DIR/enc.ctx"
DEC_SESSION_FILE="$SECRET_DIR/dec.ctx"
PRIMARY_HANDLE_FILE="$SECRET_DIR/primary.handle"

# PCR size in bytes.  Set when we determine what TPM version is in use.
# TPM1 PCRs are always 20 bytes.  TPM2 is allowed to provide multiple PCR banks
# with different algorithms - we always use SHA-256, so they are 32 bytes.
PCR_SIZE=

# Export CONFIG_TPM2_CAPTURE_PCAP=y from your board config to capture tpm2 pcaps to
# /tmp/tpm0.pcap; Wireshark can inspect these.  (This must be enabled at build
# time so the pcap TCTI driver is included.)
if [ "$CONFIG_TPM2_CAPTURE_PCAP" == "y" ]; then
	export TPM2TOOLS_TCTI="pcap:device:/dev/tpmrm0"
	export TCTI_PCAP_FILE="/tmp/tpm0.pcap"
fi

set -e -o pipefail
if [ -r "/tmp/config" ]; then
	. /tmp/config
else
	. /etc/config
fi

# Busybox xxd lacks -r, and we get hex dumps from TPM1 commands.  This converts
# a hex dump to binary data using sed and printf
hex2bin() {
	TRACE_FUNC
	sed 's/\([0-9A-F]\{2\}\)/\\\\\\x\1/gI' | xargs printf
}

# Render a password as 'hex:<hexdump>' for use with tpm2-tools.  Passwords
# should always be passed this way to avoid ambiguity.  (Passing with no prefix
# would choke if the password happened to start with 'file:' or 'hex:'.  Passing
# as a file still chokes if the password begins with 'hex:', oddly tpm2-tools
# accepts 'hex:' in the file content.)
tpm2_password_hex() {
	TRACE_FUNC
	echo "hex:$(echo -n "$1" | xxd -p | tr -d ' \n')"
}

# usage: tpmr.sh pcrread [-a] <index> <file>
# Reads PCR binary data and writes to file.
# -a: Append to file.  Default is to overwrite.
tpm2_pcrread() {
	TRACE_FUNC
	if [ "$1" = "-a" ]; then
		APPEND=y
		shift
	fi

	index="$1"
	file="$2"

	if [ -z "$APPEND" ]; then
		# Don't append - truncate file now so real command always
		# overwrites
		true >"$file"
	fi

	DO_WITH_DEBUG tpm2 pcrread -Q -o >(cat >>"$file") "sha256:$index"
}
tpm1_pcrread() {
	TRACE_FUNC
	if [ "$1" = "-a" ]; then
		APPEND=y
		shift
	fi

	index="$1"
	file="$2"

	if [ -z "$APPEND" ]; then
		# Don't append - truncate file now so real command always
		# overwrites
		true >"$file"
	fi

	DO_WITH_DEBUG tpm pcrread -ix "$index" | hex2bin >>"$file"
}

# is_hash - Check if a value is a valid hash of a given type
# usage: is_hash <alg> <value>
is_hash() {
	# Must only contain 0-9a-fA-F
	if [ "$(echo -n "$2" | tr -d '0-9a-fA-F' | wc -c)" -ne 0 ]; then return 1; fi
	# SHA-1 hashes are 40 chars
	if [ "$1" = "sha1" ] && [ "${#2}" -eq 40 ]; then return 0; fi
	# SHA-256 hashes are 64 chars
	if [ "$1" = "sha256" ] && [ "${#2}" -eq 64 ]; then return 0; fi
	return 1
}

# extend_pcr_state - extend a PCR state value with more hashes or raw data (which is hashed)
# usage:
# extend_pcr_state <alg> <state> <files/hashes...>
# alg - either 'sha1' or 'sha256' to specify algorithm
# state - a hash value setting the initial state
# files/hashes... - any number of files or hashes, state is extended once for each item
extend_pcr_state() {
	TRACE_FUNC
	local alg="$1"
	local state="$2"
	local next extend
	shift 2

	while [ "$#" -gt 0 ]; do
		next="$1"
		shift
		if is_hash "$alg" "$next"; then
			extend="$next"
		else
			extend="$("${alg}sum" <"$next" | cut -d' ' -f1)"
		fi
		state="$(echo "$state$extend" | hex2bin | "${alg}sum" | cut -d' ' -f1)"
	done
	echo "$state"
}

# There are 3 (and a half) possible formats of event log, each of them requires
# different arguments for grep. Those formats are shown below as heredocs to
# keep all the data, including whitespaces:
# 1) TPM2 log, which can hold multiple hash algorithms at once:
: <<'EOF'
TPM2 log:
	Specification: 2.00
	Platform class: PC Client
TPM2 log entry 1:
	PCR: 2
	Event type: Action
	Digests:
		 SHA256: de73053377e1ae5ba5d2b637a4f5bfaeb410137722f11ef135e7a1be524e3092
		 SHA1: 27c4f1fa214480c8626397a15981ef3a9323717f
	Event data: FMAP: FMAP
EOF
# 2) TPM1.2 log (aka TCPA), digest is always SHA1:
: <<'EOF'
TCPA log:
	Specification: 1.21
	Platform class: PC Client
TCPA log entry 1:
	PCR: 2
	Event type: Action
	Digest: 27c4f1fa214480c8626397a15981ef3a9323717f
	Event data: FMAP: FMAP
EOF
# 3) coreboot-specific format:
#   3.5) older versions printed 'coreboot TCPA log', even though it isn't TCPA
: <<'EOF'
coreboot TPM log:

 PCR-2 27c4f1fa214480c8626397a15981ef3a9323717f SHA1 [FMAP: FMAP]
EOF

# awk script to handle all of the above. Note this gets squashed to one line so
# semicolons are required.
AWK_PROG='
BEGIN {
	getline;
	hash_regex="([a-fA-F0-9]{40,})";
	if ($0 == "TPM2 log:") {
		RS="\n[^[:space:]]";
		pcr="PCR: " pcr;
		alg=toupper(alg) ": " hash_regex;
	} else if ($0 == "TCPA log:") {
		RS="\n[^[:space:]]";
		pcr="PCR: " pcr;
		alg="Digest: " hash_regex;
	} else if ($0 ~ /^coreboot (TCPA|TPM) log:$/) {
		pcr="PCR-" pcr;
		alg=hash_regex " " toupper(alg) " ";
	} else {
		print "Unknown TPM event log format:", $0 > "/dev/stderr";
		exit -1;
	}
}
$0 ~ pcr {
	match($0, alg);
	print gensub(alg, "\\1", "g", substr($0, RSTART, RLENGTH));
}
'

# usage: replay_pcr <alg> <pcr_num> [ <input_file>|<input_hash> ... ]
# Replays PCR value from CBMEM event log. Note that this contains only the
# measurements performed by firmware, without those performed by Heads (USB
# modules, LUKS header etc). First argument is PCR number, followed by optional
# hashes and/or files extended to given PCR after firmware. Resulting PCR value
# is returned in binary form.
replay_pcr() {
	TRACE_FUNC
	if [ -z "$2" ]; then
		WARN "No PCR number passed"
		return
	fi
	if [ "$2" -ge 8 ]; then
		WARN "Illegal PCR number ($2)"
		return
	fi
	local log=$(cbmem -L)
	local alg="$1"
	local pcr="$2"
	local alg_digits=0
	# SHA-1 hashes are 40 chars
	if [ "$alg" = "sha1" ]; then alg_digits=40; fi
	# SHA-256 hashes are 64 chars
	if [ "$alg" = "sha256" ]; then alg_digits=64; fi
	shift 2
	replayed_pcr=$(extend_pcr_state $alg $(printf "%.${alg_digits}d" 0) \
		$(echo "$log" | awk -v alg="$alg" -v pcr="$pcr" -f <(echo "$AWK_PROG")) "$@")
	echo $replayed_pcr | hex2bin
	DEBUG "Replayed cbmem -L clean boot state of PCR=$pcr ALG=$alg : $replayed_pcr"
	# To manually introspect current PCR values:
	# PCR-2:
	#     tpmr.sh calcfuturepcr 2 | xxd -p
	# PCR-4, in case of recovery shell (bash used for process substitution):
	#     bash -c "tpmr.sh calcfuturepcr 4 <(echo -n recovery)" | xxd -p
	# PCR-4, in case of normal boot passing through kexec-select-boot.sh:
	#     bash -c "tpmr.sh calcfuturepcr 4 <(echo -n generic)" | xxd -p
	# PCR-5, depending on which modules are loaded for given board:
	#     tpmr.sh calcfuturepcr 5 module0.ko module1.ko module2.ko | xxd -p
	# PCR-6 and PCR-7: similar to 5, but with different files passed
	#  (6: LUKS header, 7: user related cbfs files loaded from cbfs-init)
}

tpm2_extend() {
	TRACE_FUNC
	while true; do
		case "$1" in
		-ix)
			# store index and shift so -ic and -if can be processed
			index="$2"
			shift 2
			;;
		-ic)
			string=$(echo -n "$2")
			hash="$(echo -n "$2" | sha256sum | cut -d' ' -f1)"
			TRACE_FUNC
			DEBUG "TPM: Will extend PCR[$index] with hash of string $string"
			shift 2
			;;
		-if)
			TRACE_FUNC
			DEBUG "TPM: Will extend PCR[$index] with hash of file content $2"
			hash="$(sha256sum "$2" | cut -d' ' -f1)"
			shift 2
			;;
		*)
			break
			;;
		esac
	done
	tpm2 pcrextend "$index:sha256=$hash"
	INFO "TPM: Extended PCR[$index] with hash $hash"
	INFO "TPM: PCR[$index] after extend: $(tpm2 pcrread "sha256:$index" 2>&1 | tail -1)"
}

tpm2_counter_read() {
	TRACE_FUNC
	while true; do
		case "$1" in
		-ix)
			index="$2"
			shift 2
			;;
		*)
			break
			;;
		esac
	done
	local hex_val
	hex_val="$(tpm2 nvread 0x"$index" | xxd -pc8)" || return 1
	echo "$index: $hex_val"
}

tpm2_counter_inc() {
	TRACE_FUNC
	local index pwd
	local inc_args=()
	while true; do
		case "$1" in
		-ix)
			index="$2"
			shift 2
			;;
		-pwdc)
			pwd="$2"
			shift 2
			;;
		*)
			break
			;;
		esac
	done
	if [ -n "$pwd" ]; then
		inc_args=(-C o -P "$(tpm2_password_hex "$pwd")")
	fi
	tpm2 nvincrement "${inc_args[@]}" "0x$index" >/dev/console || return 1
	local hex_val
	hex_val="$(tpm2 nvread 0x"$index" | xxd -pc8)" || return 1
	echo "$index: $hex_val"
}

tpm1_counter_create() {
	TRACE_FUNC
	local attempt=0
	while true; do
		attempt=$((attempt + 1))
		prompt_tpm_owner_password
		tpm_owner_passphrase="$(cat /tmp/secret/tpm_owner_passphrase)"
		TMP_ERR_FILE=$(mktemp)
		if tpm counter_create -pwdo "$tpm_owner_passphrase" "$@" 2>"$TMP_ERR_FILE"; then
			rm -f "$TMP_ERR_FILE"
			return 0
		fi
		tmp_err_content="$(cat "$TMP_ERR_FILE")"
		rm -f "$TMP_ERR_FILE"
		DEBUG "Failed attempt $attempt to create counter from tpm1_counter_create. Stderr: $tmp_err_content"
		shred -n 10 -z -u /tmp/secret/tpm_owner_passphrase
		if echo "$tmp_err_content" | grep -qiE 'authorization|auth|bad|permission'; then
			if [ "$attempt" -ge 3 ]; then
				DIE "Unable to create counter from tpm1_counter_create after 3 attempts. Please reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) and try again."
			fi
			WARN "Counter creation failed (bad passphrase?). Retrying..."
		else
			DIE "Unable to create counter from tpm1_counter_create. Please reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) and try again."
		fi
	done
}

tpm2_counter_create() {
	TRACE_FUNC
	pass=""  # owner passphrase from argument
	label="" # label argument
	while true; do
		case "$1" in
		-pwdc)
			pass="$2"
			shift 2
			;;
		-la)
			label="$2"
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	rand_index="1$(dd if=/dev/urandom bs=1 count=3 2>/dev/null | xxd -pc3)"

	local attempt=0
	while true; do
		attempt=$((attempt + 1))
		if [ -n "$pass" ]; then
			tpm_owner_passphrase="$pass"
			mkdir -p "$SECRET_DIR" || true
			echo -n "$tpm_owner_passphrase" >/tmp/secret/tpm_owner_passphrase 2>/dev/null || true
		else
			prompt_tpm_owner_password
			tpm_owner_passphrase="$tpm_owner_passphrase"
		fi

		TMP_ERR_FILE=$(mktemp)
		if tpm2 nvdefine -C o -s 8 -a "ownerread|authread|authwrite|nt=1" \
			-P "$(tpm2_password_hex "$tpm_owner_passphrase")" "0x$rand_index" \
			2>"$TMP_ERR_FILE" >/dev/null; then
			rm -f "$TMP_ERR_FILE"
			echo "$rand_index: (valid after an increment)"
			return 0
		fi
		tmp_err_content="$(cat "$TMP_ERR_FILE")"
		rm -f "$TMP_ERR_FILE"
		shred -n 10 -z -u /tmp/secret/tpm_owner_passphrase
		DEBUG "tpm2_counter_create attempt $attempt failed. Stderr: $tmp_err_content"
		if echo "$tmp_err_content" | grep -qiE 'authorization|auth|bad|permission'; then
			if [ -n "$pass" ]; then
				DIE "Counter creation failed with provided passphrase. Please reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) and try again."
			fi
			if [ "$attempt" -ge 3 ]; then
				DIE "Unable to create counter from tpm2_counter_create after 3 attempts. Please reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) and try again."
			fi
			WARN "Counter creation failed (bad passphrase?). Retrying..."
		else
			DIE "Unable to create counter from tpm2_counter_create. Please reset the TPM using the GUI menu (Options -> TPM/TOTP/HOTP Options -> Reset the TPM) and try again."
		fi
	done
}

tpm2_startsession() {
	TRACE_FUNC
	mkdir -p "$SECRET_DIR"
	tpm2 flushcontext -Q \
		--transient-object ||
		DIE "tpm2_flushcontext: unable to flush transient handles"

	tpm2 flushcontext -Q \
		--loaded-session ||
		DIE "tpm2_flushcontext: unable to flush sessions"

	tpm2 flushcontext -Q \
		--saved-session ||
		DIE "tpm2_flushcontext: unable to flush saved session"
	tpm2 readpublic -Q -c "$PRIMARY_HANDLE" -t "$PRIMARY_HANDLE_FILE" >/dev/null 2>&1
	#TODO: do the right thing to not have to suppress "WARN: check public portion the tpmkey manually" see https://github.com/linuxboot/heads/pull/1630#issuecomment-2075120429
	tpm2 startauthsession -Q -c "$PRIMARY_HANDLE_FILE" --hmac-session -S "$ENC_SESSION_FILE" >/dev/null 2>&1
	#TODO: do the right thing to not have to suppress "WARN: check public portion the tpmkey manually" see https://github.com/linuxboot/heads/pull/1630#issuecomment-2075120429
	tpm2 startauthsession -Q -c "$PRIMARY_HANDLE_FILE" --hmac-session -S "$DEC_SESSION_FILE" >/dev/null 2>&1
	tpm2 sessionconfig -Q --disable-encrypt "$DEC_SESSION_FILE" >/dev/null 2>&1
}

# Use cleanup_session() with at_exit to release a TPM2 session and delete the
# session file.  E.g.:
#   at_exit cleanup_session "$SESSION_FILE"
cleanup_session() {
	TRACE_FUNC
	session_file="$1"
	if [ -f "$session_file" ]; then
		DEBUG "Clean up session: $session_file"
		# Nothing else we can do if this fails, still remove the file
		tpm2 flushcontext -Q "$session_file" || DEBUG "Flush failed for session $session_file"
		rm -f "$session_file"
	else
		DEBUG "No need to clean up session: $session_file"
	fi
}

# Clean up a file by shredding it.  No-op if the file wasn't created.  Use with
# at_exit, e.g.:
#   at_exit cleanup_shred "$FILE"
cleanup_shred() {
	TRACE_FUNC
	shred -n 10 -z -u "$1" 2>/dev/null || true
}

# tpm2_destroy: Destroy a sealed file in the TPM.  The mechanism differs by
# TPM version - TPM2 evicts the file object, so it no longer exists.
tpm2_destroy() {
	TRACE_FUNC
	index="$1" # Index of the sealed file
	size="$2"  # Size of zeroes to overwrite for TPM1 (unused in TPM2)

	# Pad with up to 6 zeros, i.e. '0x81000001', '0x81001234', etc.
	handle="$(printf "0x81%6s" "$index" | tr ' ' 0)"

	# remove possible data occupying this handle
	tpm2 evictcontrol -Q -C p -c "$handle" 2>/dev/null ||
		DIE "Unable to evict secret from TPM NVRAM"
}

# tpm1_destroy: Destroy a sealed file in the TPM.  The mechanism differs by
# TPM version - TPM1 overwrites the file with zeroes, since this can be done
# without authorization.  (Deletion requires authorization.)
tpm1_destroy() {
	TRACE_FUNC
	index="$1" # Index of the sealed file
	size="$2"  # Size of zeroes to overwrite for TPM1

	dd if=/dev/zero bs="$size" count=1 of=/tmp/wipe-totp.sh-zero >/dev/null 2>&1
	tpm nv_writevalue -in "$index" -if /tmp/wipe-totp.sh-zero ||
		DIE "Unable to wipe sealed secret from TPM NVRAM"
}

# tpm2_seal: Seal a file against PCR values and, optionally, a password.
# If a password is given, both the PCRs and password are required to unseal the
# file.  PCRs are provided as a PCR list and data file.  PCR data must be
# provided - TPM2 allows the TPM to fall back to current PCR values, but it is
# not required to support this.
tpm2_seal() {
	TRACE_FUNC
	file="$1" #$KEY_FILE
	index="$2"
	pcrl="$3" #0,1,2,3,4,5,6,7 (does not include algorithm prefix)
	pcrf="$4"
	sealed_size="$5"    # Not used for TPM2
	pass="$6"           # May be empty to seal with no password
	tpm_passphrase="$7" # Owner passphrase - will prompt if needed and not empty
	# TPM Owner Passphrase is always needed for TPM2.

	# bail early if the TPM hasn't been reset and we lack a primary handle.
	if [ ! -f "$PRIMARY_HANDLE_FILE" ]; then
		DIE "Unable to seal secret from TPM; no TPM primary handle. Reset the TPM (Options -> TPM/TOTP/HOTP Options -> Reset the TPM in the GUI) and try again."
	fi
	mkdir -p "$SECRET_DIR"
	bname="$(basename $file)"

	# Pad with up to 6 zeros, i.e. '0x81000001', '0x81001234', etc.
	handle="$(printf "0x81%6s" "$index" | tr ' ' 0)"

	DEBUG "tpm2_seal: file=$file handle=$handle pcrl=$pcrl pcrf=$pcrf pass=$(mask_param "$pass")"

	# Create a policy requiring both PCRs and the object's authentication
	# value using a trial session.
	TRIAL_SESSION="$SECRET_DIR/sealfile_trial.session"
	AUTH_POLICY="$SECRET_DIR/sealfile_auth.policy"
	rm -f "$TRIAL_SESSION" "$AUTH_POLICY"
	tpm2 startauthsession -g sha256 -S "$TRIAL_SESSION"
	# We have to clean up the session
	at_exit cleanup_session "$TRIAL_SESSION"
	# Save the policy hash in case the password policy is not used (we have
	# to get this from the last step, whichever it is).
	tpm2 policypcr -Q -l "sha256:$pcrl" -f "$pcrf" -S "$TRIAL_SESSION" -L "$AUTH_POLICY"
	CREATE_PASS_ARGS=()
	if [ "$pass" ]; then
		# Add an object authorization policy (the object authorization
		# will be the password).  Save the digest, this is the resulting
		# policy.
		tpm2 policyauthvalue -Q -S "$TRIAL_SESSION" -L "$AUTH_POLICY"
		# Pass the password to create later.  Pass the sha256sum of the
		# password to the TPM so the password is not limited to 32 chars
		# in length.
		CREATE_PASS_ARGS=(-p "$(tpm2_password_hex "$pass")")
	fi

	# Create the object with this policy and the auth value.
	# NOTE: We disable USERWITHAUTH and enable ADMINWITHPOLICY so the
	# password cannot be used on its own, the PCRs are also required.
	# (The default is to allow either policy auth _or_ password auth.  In
	# this case the policy includes the password, and we don't want to allow
	# the password on its own.)
	# mask hex of authorization password when supplied (it will be the
	# last parameter if CREATE_PASS_ARGS is non-empty)
	# tpm2 create: -u = public area output, -r = private (encrypted) area output.
	# File extensions match: .pub for the public area, .priv for the private area.
	DO_WITH_DEBUG --mask-position 18 tpm2 create -Q -C "$PRIMARY_HANDLE_FILE" \
		-i "$file" \
		-u "$SECRET_DIR/$bname.pub" \
		-r "$SECRET_DIR/$bname.priv" \
		-L "$AUTH_POLICY" \
		-S "$DEC_SESSION_FILE" \
		-a "fixedtpm|fixedparent|adminwithpolicy" \
		"${CREATE_PASS_ARGS[@]}"

	# tpm2 load: -u = public area input, -r = private (encrypted) area input.
	DO_WITH_DEBUG tpm2 load -Q -C "$PRIMARY_HANDLE_FILE" \
		-u "$SECRET_DIR/$bname.pub" -r "$SECRET_DIR/$bname.priv" \
		-c "$SECRET_DIR/$bname.seal.ctx"

	local attempt=0
	while true; do
		attempt=$((attempt + 1))
		prompt_tpm_owner_password
		tpm_owner_passphrase="$tpm_owner_passphrase"
		tmp_err_file="$(mktemp)"
		tpm2 evictcontrol -Q -C o -P "$(tpm2_password_hex "$tpm_owner_passphrase")" \
			-c "$handle" 2>"$tmp_err_file" || true
		if DO_WITH_DEBUG --mask-position 6 \
			tpm2 evictcontrol -Q -C o -P "$(tpm2_password_hex "$tpm_owner_passphrase")" \
			-c "$SECRET_DIR/$bname.seal.ctx" "$handle" 2>"$tmp_err_file"; then
			rm -f "$tmp_err_file"
			return 0
		fi
		tmp_err_content="$(cat "$tmp_err_file")"
		rm -f "$tmp_err_file"
		DEBUG "Failed attempt $attempt to write sealed secret to NVRAM from tpm2_seal. Stderr: $tmp_err_content"
		shred -n 10 -z -u /tmp/secret/tpm_owner_passphrase
		if echo "$tmp_err_content" | grep -qiE 'authorization|auth|bad|permission'; then
			if [ "$attempt" -ge 3 ]; then
				DIE "Unable to write sealed secret to TPM NVRAM after 3 attempts. Reset the TPM and try again."
			fi
			WARN "Failed to write sealed secret (bad passphrase?). Retrying..."
		else
			DIE "Unable to write sealed secret to TPM NVRAM. Reset the TPM and try again."
		fi
	done
}
tpm1_seal() {
	TRACE_FUNC
	local tmp_err_write tmp_err_define tmp_err_write_after_define
	file="$1"
	index="$2"
	pcrl="$3" #0,1,2,3,4,5,6,7 (does not include algorithm prefix)
	pcrf="$4"
	sealed_size="$5"
	pass="$6"                 # May be empty to seal with no password
	tpm_owner_passphrase="$7" # Owner passphrase - will prompt if needed and not empty

	sealed_file="$SECRET_DIR/tpm1_seal_sealed.bin"
	at_exit cleanup_shred "$sealed_file"

	POLICY_ARGS=()

	DEBUG "tpm1_seal arguments: file=$file index=$index pcrl=$pcrl pcrf=$pcrf sealed_size=$sealed_size pass=$(mask_param "$pass") tpm_owner_passphrase=$(mask_param "$tpm_owner_passphrase")"

	# If a passphrase was given, add it to the policy arguments
	if [ "$pass" ]; then
		POLICY_ARGS+=(-pwdd "$pass")
	fi

	# Transform the PCR list and PCR file to discrete arguments
	IFS=',' read -r -a PCR_LIST <<<"$pcrl"
	pcr_file_index=0
	for pcr in "${PCR_LIST[@]}"; do
		# Read each PCR_SIZE block from the file and pass as hex
		POLICY_ARGS+=(-ix "$pcr"
			"$(dd if="$pcrf" skip="$pcr_file_index" bs="$PCR_SIZE" count=1 status=none | xxd -p | tr -d ' ')"
		)
		pcr_file_index=$((pcr_file_index + 1))
	done

	tpm sealfile2 \
		-if "$file" \
		-of "$sealed_file" \
		-hk 40000000 \
		"${POLICY_ARGS[@]}"
	DEBUG "tpm1_seal: sealed blob created at $sealed_file (size=$(wc -c <"$sealed_file" 2>/dev/null || echo 0) bytes), target nv index=$index"

	local attempt=0
	while true; do
		attempt=$((attempt + 1))
		tmp_err_write="$(mktemp)"
		if tpm nv_writevalue -in "$index" -if "$sealed_file" 2>"$tmp_err_write"; then
			rm -f "$tmp_err_write"
			return 0
		fi
		tmp_err_content="$(cat "$tmp_err_write")"
		rm -f "$tmp_err_write"
		if ! echo "$tmp_err_content" | grep -qi 'illegal index'; then
			DEBUG "tpm1_seal nv_writevalue(pre-define) stderr: $tmp_err_content"
			DEBUG "Failed to write sealed secret to NVRAM from tpm1_seal (unexpected error). Wiping /tmp/secret/tpm_owner_passphrase"
			shred -n 10 -z -u /tmp/secret/tpm_owner_passphrase
			DIE "Unable to write sealed secret to TPM NVRAM"
		fi
		DEBUG "tpm1_seal: nv index $index is not defined yet (Illegal index); attempting nv_definespace"

		tpm physicalpresence -s ||
			{
				WARN "Unable to assert physical presence"
			}

		prompt_tpm_owner_password
		tpm_owner_passphrase="$(cat /tmp/secret/tpm_owner_passphrase)"
		tmp_err_define="$(mktemp)"
		if ! DO_WITH_DEBUG --mask-position 7 tpm nv_definespace -in "$index" -sz "$sealed_size" \
			-pwdo "$tpm_owner_passphrase" -per 0 2>"$tmp_err_define"; then
			tmp_err_define_content="$(cat "$tmp_err_define")"
			rm -f "$tmp_err_define"
			DEBUG "tpm1_seal nv_definespace stderr: $tmp_err_define_content"
			WARN "Unable to define TPM NVRAM space; trying anyway"
		else
			rm -f "$tmp_err_define"
		fi

		tmp_err_write_after_define="$(mktemp)"
		if tpm nv_writevalue -in "$index" -if "$sealed_file" 2>"$tmp_err_write_after_define"; then
			rm -f "$tmp_err_write_after_define"
			return 0
		fi
		tmp_err_content="$(cat "$tmp_err_write_after_define")"
		rm -f "$tmp_err_write_after_define"
		DEBUG "tpm1_seal nv_writevalue(post-define) stderr: $tmp_err_content"
		DEBUG "Failed attempt $attempt to write sealed secret to NVRAM from tpm1_seal. Wiping /tmp/secret/tpm_owner_passphrase"
		shred -n 10 -z -u /tmp/secret/tpm_owner_passphrase
		if echo "$tmp_err_content" | grep -qiE 'authorization|auth|bad|permission'; then
			if [ "$attempt" -ge 3 ]; then
				DIE "Unable to write sealed secret to TPM NVRAM after 3 attempts"
			fi
			WARN "Failed to write sealed secret (bad passphrase?). Retrying..."
		else
			DIE "Unable to write sealed secret to TPM NVRAM"
		fi
	done
}

# Unseal a file sealed by tpm2_seal.  The PCR list must be provided, the
# password must be provided if one was used to seal (and cannot be provided if
# no password was used to seal).
tpm2_unseal() {
	TRACE_FUNC
	index="$1"
	pcrl="$2" #0,1,2,3,4,5,6,7 (does not include algorithm prefix)
	sealed_size="$3"
	file="$4"
	pass="$5"

	# TPM2 doesn't care about sealed_size, only TPM1 needs that.  We don't
	# have to separately read the sealed file on TPM2.

	# Pad with up to 6 zeros, i.e. '0x81000001', '0x81001234', etc.
	handle="$(printf "0x81%6s" "$index" | tr ' ' 0)"

	DEBUG "tpm2_unseal: handle=$handle pcrl=$pcrl file=$file pass=$(mask_param "$pass")"

	# If we don't have the primary handle (TPM hasn't been reset), tpm2 will
	# print nonsense error messages about an unexpected handle value.  We
	# can't do anything without a primary handle.
	if [ ! -f "$PRIMARY_HANDLE_FILE" ]; then
		DEBUG "tpm2_unseal: No primary handle, cannot attempt to unseal"
		WARN "No TPM primary handle. Reset the TPM (Options -> TPM/TOTP/HOTP Options -> Reset the TPM in the GUI) before attempting to unseal a secret from TPM NVRAM"
		exit 1
	fi

	POLICY_SESSION="$SECRET_DIR/unsealfile_policy.session"
	rm -f "$POLICY_SESSION"
	tpm2 startauthsession -Q -g sha256 -S "$POLICY_SESSION" --policy-session
	at_exit cleanup_session "$POLICY_SESSION"
	# Check the PCR policy
	tpm2 policypcr -Q -l "sha256:$pcrl" -S "$POLICY_SESSION"
	UNSEAL_PASS_SUFFIX=""

	if [ "$pass" ]; then
		# Add the object authorization policy (the actual password is
		# provided later, but we must include this so the policy we
		# attempt to use is correct).
		tpm2 policyauthvalue -Q -S "$POLICY_SESSION"
		# When unsealing, include the password with the auth session
		UNSEAL_PASS_SUFFIX="+$(tpm2_password_hex "$pass")"
	fi

	# tpm2 unseal will write the unsealed data to stdout and any errors to
	# stderr; capture stderr to log.
	if ! tpm2 unseal -Q -c "$handle" -p "session:$POLICY_SESSION$UNSEAL_PASS_SUFFIX" \
		-S "$ENC_SESSION_FILE" >"$file" 2> >(SINK_LOG "tpm2 stderr"); then
		WARN "Unable to unseal secret from TPM NVRAM"

		# should succeed, exit if it doesn't
		exit 1
	fi
	rm -f "$TMP_ERR_FILE"
}

tpm1_unseal() {
	TRACE_FUNC
	local tmp_err_read
	index="$1"
	pcrl="$2"
	sealed_size="$3"
	file="$4"
	pass="$5"

	# pcrl (the PCR list) is unused in TPM1.  The TPM itself knows which
	# PCRs were used to seal and checks them.  We can't verify that it's
	# correct either, so just ignore it in TPM1.

	sealed_file="$SECRET_DIR/tpm1_unseal_sealed.bin"
	at_exit cleanup_shred "$sealed_file"

	rm -f "$sealed_file"

	# Read the sealed blob from NVRAM.  `tpm nv_readvalue` prints a
	# spurious warning about index size that we don't want on the console;
	# capture stderr in the debug log instead.  Password prompts are written
	# directly to the tty and are unaffected by this redirection.
	tmp_err_read="$(mktemp)"
	if ! DO_WITH_DEBUG tpm nv_readvalue \
		-in "$index" \
		-sz "$sealed_size" \
		-of "$sealed_file" \
		2>"$tmp_err_read"; then
		while IFS= read -r line; do
			DEBUG "tpm1_unseal nv_readvalue stderr: $line"
		done <"$tmp_err_read"
		rm -f "$tmp_err_read"
		if [ "$HEADS_NONFATAL_UNSEAL" = "y" ]; then
			DEBUG "nonfatal tpm1_unseal failure: unable to read sealed file from TPM NVRAM"
			return 1
		fi
		DIE "Unable to read sealed file from TPM NVRAM. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal."
	fi
	rm -f "$tmp_err_read"

	PASS_ARGS=()
	if [ "$pass" ]; then
		PASS_ARGS=(-pwdd "$pass")
	fi

	if [ -n "$pass" ]; then
		if ! DO_WITH_DEBUG --mask-position 7 tpm unsealfile \
			-if "$sealed_file" \
			-of "$file" \
			"${PASS_ARGS[@]}" \
			-hk 40000000; then
			if [ "$HEADS_NONFATAL_UNSEAL" = "y" ]; then
				DEBUG "nonfatal tpm1_unseal failure: unable to unseal TPM NVRAM blob"
				return 1
			fi
			DIE "Unable to unseal secret from TPM NVRAM. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal."
		fi
	else
		if ! DO_WITH_DEBUG tpm unsealfile \
			-if "$sealed_file" \
			-of "$file" \
			-hk 40000000; then
			if [ "$HEADS_NONFATAL_UNSEAL" = "y" ]; then
				DEBUG "nonfatal tpm1_unseal failure: unable to unseal TPM NVRAM blob"
				return 1
			fi
			DIE "Unable to unseal secret from TPM NVRAM. Use the GUI menu (Options -> TPM/TOTP/HOTP Options -> Generate new TOTP/HOTP secret) to reseal."
		fi
	fi
}

# cache_owner_passphrase <passphrase>
# Store the TPM owner passphrase in SECRET_DIR for the current boot session.
# The original callers wrote the passphrase to a file directly; the helper
# provides identical behaviour and keeps the code DRY.
cache_owner_password() {
	TRACE_FUNC
	mkdir -p "$SECRET_DIR"
	DEBUG "Caching TPM Owner Passphrase to $SECRET_DIR/tpm_owner_passphrase"
	printf '%s' "$1" >"$SECRET_DIR/tpm_owner_passphrase"
}

# Reset a TPM2 device for Heads.  (Previous versions in origin/master put the
# comment about caching directly in this function, which is preserved below.)
tpm2_reset() {
	TRACE_FUNC
	tpm_owner_passphrase="$1"
	# output TPM Owner Passphrase to a file to be reused in this boot session until recovery shell/reboot
	# (using cache_owner_password() to avoid duplicating the write logic)
	cache_owner_password "$tpm_owner_passphrase"

	# 1. Ensure TPM2_Clear is allowed: clear disableClear via platform hierarchy.
	#    This makes future clears (Owner/Lockout) possible and avoids a 'no clear' stuck state.
	if ! DO_WITH_DEBUG tpm2 clearcontrol -C platform c >/dev/null 2>&1; then
		LOG "tpm2_reset: unable to clear disableClear via platform hierarchy"
		return 1
	fi

	# 2. Factory-style clear via platform hierarchy.
	#    This destroys all previous owner/endorsement/lockout auth and user-created objects.
	if ! DO_WITH_DEBUG tpm2 clear -c platform >/dev/null 2>&1; then
		LOG "tpm2_reset: TPM2_Clear via platform hierarchy failed; TPM not reset"
		return 1
	fi

	# 3. Re-own the TPM for Heads: set new owner and endorsement auth.
	# don't echo the owner passphrase in debug logs
	# hide the owner auth hex (argument index 4)
	if ! DO_WITH_DEBUG --mask-position 4 tpm2 changeauth -c owner "$(tpm2_password_hex "$tpm_owner_passphrase")" >/dev/null 2>&1; then
		LOG "tpm2_reset: unable to set owner auth"
		return 1
	fi

	# mask endorsement passphrase too (argument index 4)
	if ! DO_WITH_DEBUG --mask-position 4 tpm2 changeauth -c endorsement "$(tpm2_password_hex "$tpm_owner_passphrase")" >/dev/null 2>&1; then
		LOG "tpm2_reset: unable to set endorsement auth"
		return 1
	fi

	# 4. Create and persist Heads primary key.
	# hide owner passphrase during primary creation (argument index 11)
	if ! DO_WITH_DEBUG --mask-position 11 tpm2 createprimary -C owner -g sha256 -G "${CONFIG_PRIMARY_KEY_TYPE:-rsa}" \
		-c "$SECRET_DIR/primary.ctx" \
		-P "$(tpm2_password_hex "$tpm_owner_passphrase")" >/dev/null 2>&1; then
		LOG "tpm2_reset: unable to create primary"
		return 1
	fi

	# and hide passphrase when evicting the primary handle (argument index 8)
	if ! DO_WITH_DEBUG --mask-position 8 tpm2 evictcontrol -C owner -c "$SECRET_DIR/primary.ctx" "$PRIMARY_HANDLE" \
		-P "$(tpm2_password_hex "$tpm_owner_passphrase")" >/dev/null 2>&1; then
		LOG "tpm2_reset: unable to persist primary"
		shred -u "$SECRET_DIR/primary.ctx" >/dev/null 2>&1
		return 1
	fi

	shred -u "$SECRET_DIR/primary.ctx" >/dev/null 2>&1

	DO_WITH_DEBUG tpm2_startsession >/dev/null 2>&1

	# Set the dictionary attack parameters.  TPM2 defaults vary widely, we
	# want consistent behavior on any TPM.
	# * --max-tries=10: Allow 10 failures before lockout.  This allows the
	#   user to quickly "burst" 10 failures without significantly impacting
	#   the rate allowed for a dictionary attacker.
	#   Most TPM2 flows ask for the TPM Owner Passphrase 2-4 times, so this allows
	#   a handful of mistypes and some headroom for an expected unseal
	#   failure if firmware is updated.
	#   Remember that an auth failure is also counted any time an unclean
	#   shutdown occurs (see TPM2 spec part 1, section 19.8.6, "Non-orderly
	#   Shutdown").
	# * --recovery-time=3600: Forget an auth failure every 1 hour.
	# * --lockout-recovery-time: After a failed lockout recovery auth, the
	#   TPM must be reset to try again.
	#
	# Heads does not offer a way to reset dictionary attack lockout, instead
	# the TPM can be reset and new secrets sealed.
	tpm2 dictionarylockout -Q --setup-parameters \
		--max-tries=10 \
		--recovery-time=3600 \
		--lockout-recovery-time=0 \
		--auth="session:$ENC_SESSION_FILE" >/dev/null 2>&1 ||
		LOG "tpm2_reset: unable to set dictionary lockout parameters"

	# 6. Set a random DA lockout password so DA reset requires another TPM reset.
	# The default lockout password is empty, so we must set this, and we
	# don't need to provide any auth (use the default empty password).
	tpm2 changeauth -Q -c lockout \
		"hex:$(dd if=/dev/urandom bs=32 count=1 status=none 2>/dev/null | xxd -p | tr -d ' \n')" \
		>/dev/null 2>&1 || LOG "tpm2_reset: unable to set lockout password"
}

tpm1_reset() {
	TRACE_FUNC
	tpm_owner_passphrase="$1"
	# output tpm_owner_passphrase to a file to be reused in this boot session until recovery shell/reboot
	# (using cache_owner_password() under the hood)
	cache_owner_password "$tpm_owner_passphrase"

	# 1. Request physical presence and enable TPM.
	DO_WITH_DEBUG tpm physicalpresence -s >/dev/null 2>&1 || LOG "tpm1_reset: unable to set physical presence"
	DO_WITH_DEBUG tpm physicalenable >/dev/null 2>&1 || LOG "tpm1_reset: unable to physicalenable"

	# Ensure TPM is not deactivated.
	DO_WITH_DEBUG tpm physicalsetdeactivated -c >/dev/null 2>&1 || LOG "tpm1_reset: unable to clear deactivated state"

	# 2. Force clear: this is the critical full reset for TPM 1.2.
	if ! DO_WITH_DEBUG tpm forceclear >/dev/null 2>&1; then
		LOG "tpm1_reset: tpm forceclear failed; TPM not reset (firmware policy or state blocking clear)"
		return 1
	fi

	# Re-enable after clear (some platforms require this).
	DO_WITH_DEBUG tpm physicalenable >/dev/null 2>&1 || LOG "tpm1_reset: unable to physicalenable after clear"

	# 3. Take ownership with the new TPM owner passphrase.
	if ! DO_WITH_DEBUG --mask-position 3 tpm takeown -pwdo "$tpm_owner_passphrase" >/dev/null 2>&1; then
		LOG "tpm1_reset: tpm takeown failed after forceclear"
		return 1
	fi

	# 4. Leave TPM enabled, present, and not deactivated.
	DO_WITH_DEBUG tpm physicalpresence -s >/dev/null 2>&1 || LOG "tpm1_reset: unable to set physical presence (final)"
	DO_WITH_DEBUG tpm physicalenable >/dev/null 2>&1 || LOG "tpm1_reset: unable to physicalenable (final)"
	DO_WITH_DEBUG tpm physicalsetdeactivated -c >/dev/null 2>&1 || LOG "tpm1_reset: unable to clear deactivated state (final)"
}

# Perform final cleanup before boot and lock the platform heirarchy.
tpm2_kexec_finalize() {
	TRACE_FUNC

	# Flush sessions and transient objects
	tpm2 flushcontext -Q --transient-object ||
		WARN "tpm2_flushcontext: unable to flush transient handles"
	tpm2 flushcontext -Q --loaded-session ||
		WARN "tpm2_flushcontext: unable to flush sessions"
	tpm2 flushcontext -Q --saved-session ||
		WARN "tpm2_flushcontext: unable to flush saved session"

	# Add a random passphrase to platform hierarchy to prevent TPM2 from
	# being cleared in the OS.
	# This passphrase is only effective before the next boot.
	INFO "TPM: Locking TPM2 platform hierarchy"
	randpass=$(dd if=/dev/urandom bs=4 count=1 status=none 2>/dev/null | xxd -p)
	tpm2 changeauth -c platform "$randpass" ||
		WARN "Failed to lock platform hierarchy of TPM2"
}

tpm2_shutdown() {
	TRACE_FUNC

	# Prepare for shutdown.
	# This is a "clear" shutdown (do not preserve runtime state) since we
	# are not going to resume later, we are powering off (or rebooting).
	tpm2 shutdown -Q --clear
}

if [ "$CONFIG_TPM" != "y" ]; then
	DIE "No TPM!"
fi

# TPM1 - most commands forward directly to tpm, but some are still wrapped for
# consistency with tpm2.
if [ "$CONFIG_TPM2_TOOLS" != "y" ]; then
	PCR_SIZE=20 # TPM1 PCRs are always SHA-1
	subcmd="$1"
	# Don't shift yet, for most commands we will just forward to tpm.
	case "$subcmd" in
	pcrread)
		shift
		tpm1_pcrread "$@"
		;;
	pcrsize)
		echo "$PCR_SIZE"
		;;
	calcfuturepcr)
		shift
		replay_pcr "sha1" "$@"
		;;
	counter_create)
		shift
		tpm1_counter_create "$@"
		;;
	destroy)
		shift
		tpm1_destroy "$@"
		;;
	extend)
		# Check if we extend with a hash or a file
		if [ "$4" = "-if" ]; then
			hash="$(sha1sum "$5" | cut -d' ' -f1)"
			INFO "TPM: Extending PCR[$3] with content of $5 (hash: $hash)"
		elif [ "$4" = "-ic" ]; then
			string=$(echo -n "$5")
			hash="$(echo -n "$5" | sha1sum | cut -d' ' -f1)"
			INFO "TPM: Extending PCR[$3] with content of string '$5' (hash: $hash)"
		fi

		TRACE_FUNC
		# Silence stdout/stderr, they're only useful for debugging
		# and DO_WITH_DEBUG captures them
		DO_WITH_DEBUG exec tpm "$@" &>/dev/null

		# Read PCR value after extend (TPM1 uses SHA1, read from sysfs)
		pcr_value=$(grep -i "PCR-0*$3:" /sys/class/tpm/tpm0/pcrs | head -1 | cut -d: -f2 | tr -d ' ')
		INFO "TPM: PCR[$3] after extend: $pcr_value"
		INFO "TPM: Extended PCR[$3] with hash $hash"
		;;
	seal)
		shift
		tpm1_seal "$@"
		;;
	startsession) ;; # Nothing on TPM1.
	unseal)
		shift
		tpm1_unseal "$@"
		;;
	reset)
		shift
		INFO "TPM: Resetting TPM"
		tpm1_reset "$@"
		STATUS_OK "TPM reset completed"
		;;
	kexec_finalize) ;; # Nothing on TPM1.
	shutdown) ;;       # Nothing on TPM1.
	*)
		# Keep passthrough raw here: callers decide whether to wrap with
		# DO_WITH_DEBUG (and --mask-position when passing secrets).
		DEBUG "Direct translation from tpmr.sh to tpm1 call"
		exec tpm "$@"
		;;
	esac
	exit 0
fi

# TPM2 - all commands implemented as wrappers around tpm2
PCR_SIZE=32 # We use the SHA-256 PCRs
subcmd="$1"
shift 1
case "$subcmd" in
pcrread)
	tpm2_pcrread "$@"
	;;
pcrsize)
	echo "$PCR_SIZE"
	;;
calcfuturepcr)
	replay_pcr "sha256" "$@"
	;;
	extend)
	TRACE_FUNC
	# Show INFO message with what's being extended for auditability
	# -ic: extend with string, -if: extend with file content
	if [ "$3" = "-ic" ]; then
		# -ic: the string is passed directly
		hash="$(echo -n "$4" | sha256sum | cut -d' ' -f1)"
		INFO "TPM: Extending PCR[$2] with content of string '$4' (hash: $hash)"
	else
		# -if: the file content is used
		hash="$(sha256sum "$4" | cut -d' ' -f1)"
		INFO "TPM: Extending PCR[$2] with content of $4 (hash: $hash)"
	fi
	tpm2_extend "$@"
	;;
counter_read)
	tpm2_counter_read "$@"
	;;
counter_increment)
	tpm2_counter_inc "$@"
	;;
counter_create)
	tpm2_counter_create "$@"
	;;
destroy)
	tpm2_destroy "$@"
	;;
seal)
	tpm2_seal "$@"
	;;
startsession)
	tpm2_startsession "$@"
	;;
unseal)
	tpm2_unseal "$@"
	;;
reset)
	INFO "TPM: Resetting TPM"
	tpm2_reset "$@"
	STATUS_OK "TPM reset completed"
	;;
kexec_finalize)
	tpm2_kexec_finalize "$@"
	;;
shutdown)
	tpm2_shutdown "$@"
	;;
*)
	DIE "Command $subcmd not wrapped!"
	;;
esac
