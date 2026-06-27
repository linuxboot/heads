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
		next_byte="$(dd bs=1 count=1 status=none | tohex_plain)"
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
		# Accept either exit code  --  extraction was successful either way.
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
	magic="$(dd if="$unpack_archive" bs=6 count=1 status=none 2>/dev/null | tohex_plain)"

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
			# BusyBox cpio stops at the first TRAILER; GNU cpio reads past
			# it and consumes subsequent segments.  Find the TRAILER offset
			# so we can limit cpio's input to exactly one segment.
			_trailer_off=$(strings -t d "$unpack_archive" 2>/dev/null | \
				grep -F 'TRAILER!!!' | head -1 | awk '{print $1}') || true
			if [ -n "$_trailer_off" ]; then
				# In new-format cpio the entire header is ASCII hex digits,
				# so `strings` sees one continuous printable string from the
				# entry header through the filename.  _trailer_off points to
				# the START of the TRAILER entry header (not the filename).
				# TRAILER namesize is always 11 ("TRAILER!!!\0") and filesize
				# is 0.  Entry size = ROUNDUP(110 + 11, 4) = 124 bytes.
				_seg_end=$((_trailer_off + 124))
				dd bs="$_seg_end" count=1 status=none 2>/dev/null | (
					cd "$dest_dir" && cpio -i -d "${CPIO_ARGS[@]}" 2>/dev/null
				) || true
				cat || true
			else
				unpack_cpio
				cat || true
			fi
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
			# The following are magic values for other compression formats
			#  but not added because not tested.
			# TODO: open an issue for unsupported magic number reported on DIE.
			# 
			#425a*) # bzip2
			#	DEBUG "archive segment $magic: bzip2"
			#	bunzip2 | unpack_cpio
			#;;
			#5d00*) # lzma
			#	DEBUG "archive segment $magic: lzma"
			#	unlzma | unpack_cpio
			#;;
			#894c*) # lzo
			#	DEBUG "archive segment $magic: lzo"
			#	lzop -d | unpack_cpio
			#;;
			#0221*) # lz4
			#	DEBUG "archive segment $magic: lz4"
			#	lz4 -d | unpack_cpio
			#	;;
			;;
		esac
	) <"$unpack_archive" >"$rest_archive"

	orig_size="$(stat -c %s "$unpack_archive")"
	rest_size="$(stat -c %s "$rest_archive")"
	DEBUG "archive segment $magic: $((orig_size - rest_size)) bytes"
}

DEBUG "Unpacking $INITRAMFS_ARCHIVE to $DEST_DIR"

next_archive="$INITRAMFS_ARCHIVE"
# Temp files for intermediate segments.  Using mktemp avoids collision when
# multiple unpacker instances run in parallel (e.g. test harness).
# The cleanup trap removes these when the script exits.
rest_archive="$(mktemp /tmp/unpack_initramfs_rest_XXXXXX 2>/dev/null)" || rest_archive="/tmp/unpack_initramfs_rest_$$"
next_segment="$(mktemp /tmp/unpack_initramfs_next_XXXXXX 2>/dev/null)" || next_segment="/tmp/unpack_initramfs_next_$$"
trap 'rm -f "$rest_archive" "$next_segment"' EXIT

# Break when there is no remaining data
while [ -s "$next_archive" ]; do
	unpack_first_segment "$next_archive" "$DEST_DIR" "$rest_archive"
	mv "$rest_archive" "$next_segment"
	# next_archive and next_segment point to the same file after the mv;
	# keep them in sync so both reference the correct current segment.
	next_archive="$next_segment"
	# GNU cpio reads past the first TRAILER and consumes all cpio entries
	# across concatenated segments, leaving only residual bytes.  BusyBox
	# cpio stops at the first TRAILER.  If only a few bytes remain (< min
	# cpio header = 110 bytes), we're done.
	rest_size="$(stat -c %s "$next_archive" 2>/dev/null || echo 0)"
	[ "$rest_size" -lt 110 ] && break
done
