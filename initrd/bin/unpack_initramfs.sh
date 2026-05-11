#! /bin/bash
set -e -o pipefail

. /etc/functions.sh

TRACE_FUNC
# Unpack a Linux initramfs archive.
#
# In general, the initramfs archive is one or more cpio archives, optionally
# compressed, concatenated together.  Uncompressed and compressed segments can
# exist in the same file.  Zero bytes between segments are skipped.  To properly
# unpack such an archive, all segments must be unpacked.
#
# This script unpacks such an archive, but with a limitation that once a
# compressed segment is reached, no more segments can be read.  This works for
# common initrds on x86, where the microcode must be stored in an initial
# uncompressed segment, followed by the "real" initramfs content which is
# usually in one compressed segment.
#
# The limitation comes from gunzip/unzstd, there's no way to prevent them from
# consuming trailing data or tell us the member/frame length.  The script
# succeeds with whatever was extracted, since this is used to extract particular
# files and boot can proceed as long as those files were found.

INITRAMFS_ARCHIVE="$1"
DEST_DIR="$2"
shift
shift
# rest of args go to cpio, can specify filename patterns
CPIO_ARGS=("$@")

# Consume zero bytes, the first nonzero byte read (if any) is repeated on stdout
consume_zeros() {
	TRACE_FUNC
	next_byte='00'
	while [ "$next_byte" = "00" ]; do
		# if we reach EOF, next_byte becomes empty (dd does not fail)
		next_byte="$(dd bs=1 count=1 status=none | xxd -p | tr -d '\n ')"
	done
	# if we finished due to nonzero byte (not EOF), then carry that byte
	if [ -n "$next_byte" ]; then
		echo -n "$next_byte" | xxd -p -r
	fi
}

unpack_cpio() {
	(
		cd "$dest_dir"
		# GNU cpio exits non-zero when trailing data follows the TRAILER entry
		# in a concatenated multi-segment archive.  BusyBox cpio ignores it.
		# Accept either exit code — extraction was successful either way.
		cpio -i -d "${CPIO_ARGS[@]}" 2>/dev/null || true
	)
}

# unpack the first segment of an archive, then write the rest to another file
unpack_first_segment() {
	TRACE_FUNC
	unpack_archive="$1"
	dest_dir="$2"
	rest_archive="$3"

	mkdir -p "$dest_dir"

	# peek the beginning of the file to determine what type of content is next
	magic="$(dd if="$unpack_archive" bs=6 count=1 status=none 2>/dev/null | xxd -p | tr -d '\n ')"

	# For plain cpio, find where the first TRAILER entry ends.  GNU cpio reads
	# past the first TRAILER and consumes subsequent segments; BusyBox cpio
	# stops at the first.  By limiting cpio's input to the first segment,
	# both behave the same and remaining segments are processed correctly.
	local segment_end=0
	case "$magic" in
	303730373031* | 303730373032*)
		local trailer_off
		trailer_off=$(grep -F -b -o "TRAILER!!!" "$unpack_archive" 2>/dev/null | head -1 | cut -d: -f1) || true
		if [ -n "$trailer_off" ]; then
			# TRAILER entry: header(110) + filename "TRAILER!!!" padded to 12 = 122 bytes
			segment_end=$((trailer_off + 12))
		fi
		;;
	esac

	# read this segment of the archive, then write the rest to the next file
	(
		case "$magic" in
		00*)
			DEBUG "archive segment $magic: uncompressed cpio"
			consume_zeros
			cat
			;;
		303730373031* | 303730373032*) # plain cpio
			DEBUG "archive segment $magic: plain cpio"
			if [ "$segment_end" -gt 0 ]; then
				# Feed exactly one segment to cpio so it doesn't consume
				# subsequent segments (GNU cpio reads past the first TRAILER).
				# Use dd bs=N count=1 — unlike head -c, it reads exactly N
				# bytes without buffering extra data from stdin.
				dd bs="$segment_end" count=1 status=none 2>/dev/null | (
					cd "$dest_dir" && cpio -i -d "${CPIO_ARGS[@]}" 2>/dev/null
				) || true
			else
				unpack_cpio
			fi
			cat || true
			;;
		1f8b* | 1f9e*) # gzip
			DEBUG "archive segment $magic: gzip"
			gunzip | unpack_cpio
			;;
		fd37*) # xz
			DEBUG "archive segment $magic: xz"
			unxz | unpack_cpio
			;;
		28b5*) # zstd
			DEBUG "archive segment $magic: zstd"
			(zstd-decompress -d 2>/dev/null || zstd -d 2>/dev/null || true) | unpack_cpio
			;;
		*) # unknown
			DIE "Can't decompress initramfs archive, unknown type: $magic"
			;;
		esac
	) <"$unpack_archive" >"$rest_archive"

	orig_size="$(stat -c %s "$unpack_archive")"
	rest_size="$(stat -c %s "$rest_archive")"
	DEBUG "archive segment $magic: $((orig_size - rest_size)) bytes"
}

DEBUG "Unpacking $INITRAMFS_ARCHIVE to $DEST_DIR"

next_archive="$INITRAMFS_ARCHIVE"
rest_archive="/tmp/unpack_initramfs_rest"

# Break when there is no remaining data
while [ -s "$next_archive" ]; do
	unpack_first_segment "$next_archive" "$DEST_DIR" "$rest_archive"
	next_archive="/tmp/unpack_initramfs_next"
	mv "$rest_archive" "$next_archive"
	# GNU cpio reads past the first TRAILER and consumes all cpio entries
	# across concatenated segments, leaving only residual bytes.  BusyBox
	# cpio stops at the first TRAILER.  If only a few bytes remain (< min
	# cpio header = 110 bytes), we're done.
	rest_size="$(stat -c %s "$next_archive" 2>/dev/null || echo 0)"
	[ "$rest_size" -lt 110 ] && break
done
