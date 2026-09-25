#!/usr/bin/env perl
# Clean all non-deterministric fields in a newc cpio file
#
# Items fixed:
# Entries are sorted directories-first (by path), then the remaining
#   entries by (extension, size descending, name).  Directories must come
#   first: the kernel skips a file whose parent directory has not been
#   unpacked yet (init/initramfs.c:do_name() returns without opening it).
#   Grouping like payloads together then gives the downstream xz filter a
#   more uniform context.
# Inode numbers are set to zero
# File timestamp is set to 1970-01-01T00:00:00
# uid/gid are set to root
# check field is zeroed
# nlinks is set to zero, since the filesystem manages it
#
# The inode is written as 0 rather than a hash of the name.  This is safe
# because nlink is also 0 and the kernel (init/initramfs.c) only builds a
# hardlink key when nlink >= 2; with nlink=0 it never looks the inode up.
# Directory entries are always kept: the kernel does not create missing
# parents.  Hardlink de-duplication must NOT be combined with a zeroed
# inode, since every entry would then share the same link key.
#
use warnings;
use strict;
use Data::Dumper;

#	   struct cpio_newc_header {
#		   char    c_magic[6]; -6
#		   char    c_ino[8]; -- set to zero
#		   char    c_mode[8]; 8
#		   char    c_uid[8]; 16
#		   char    c_gid[8];  24
#		   char    c_nlink[8]; 32
#		   char    c_mtime[8]; 40 -- set to zero
#		   char    c_filesize[8]; 48
#		   char    c_devmajor[8]; 56
#		   char    c_devminor[8]; 64
#		   char    c_rdevmajor[8]; 72
#		   char    c_rdevminor[8]; 80
#		   char    c_namesize[8]; 88
#		   char    c_check[8]; 96
#	   }; // 104
# followed by namesize bytes of name (padded to be a multiple of 4)
# followed dby filesize bytes of file (padded to be a multiple of 4)

# Read the entire file at once
undef $/;

# Fail fast if a named input cannot be opened.  The diamond operator only
# warns and moves on to the next file, so an unreadable input would
# otherwise yield a module-less initrd while still exiting 0.  ('-' means
# standard input.)
for my $file (@ARGV)
{
	next if $file eq '-';
	open my $fh, '<', $file or die "$file: $!\n";
	close $fh;
}

# Generate a map of all of the files in the cpio archive
# This will also merge multiple cpio files
my %entries;
my $trailer;

while(<>)
{
	for(my $i = 0 ; $i < length $_ ; )
	{
		my $magic = substr($_, $i, 6);
		if ($magic ne "070701")
		{
			die "$ARGV: offset $i: invalid magic '$magic'\n";
		}

		my $namesize = substr($_, $i + 6+88, 8);
		my $filesize = substr($_, $i + 6+48, 8);

		if ($namesize =~ /[^0-9A-Fa-f]/)
		{
			die "$ARGV: offset $i: invalid characters in namesize '$namesize'\n";
		}

		if ($filesize =~ /[^0-9A-Fa-f]/)
		{
			die "$ARGV: offset $i: invalid characters in filesize '$filesize'\n";
		}

		# Convert them to hex
		$namesize = hex $namesize;
		$filesize = hex $filesize;

		#print STDERR "name: '$namesize', filesize: '$filesize'\n";

		my $name = substr($_, $i + 6+104, $namesize);
		#print STDERR Dumper($name);

		# Align the header size to be a multiple of four bytes
		my $entry_size = (6+104 + $namesize + 3) & ~3;
		$entry_size += ($filesize + 3) & ~3;

		my $entry = substr($_, $i, $entry_size);
		$i += $entry_size;

		if ($name =~ /^TRAILER!!!/)
		{
			$trailer = $entry;
			last;
		}

		$entries{$name} = $entry;
	}

	die "$ARGV: No trailer!\n" unless $trailer;
}

# The per-read check above only runs when the read loop actually yields a
# record, and a read that yields none leaves $trailer undefined: a directory
# is opened successfully by the preflight loop but never produces a record,
# and a truncated archive stops before its TRAILER!!! entry.  Writing the
# output below in that state would append an undefined trailer to an empty
# archive and exit 0, so refuse to produce an archive with no end marker.
die "$ARGV: No trailer!\n" unless defined $trailer;

# True for directory members.
sub is_dir
{
	my ($entry) = @_;

	my $mode = hex substr($entry, 6 + 8, 8);
	return (($mode & 0170000) == 0040000);
}

# Extension of the basename, or '' when there is none.
sub entry_ext
{
	my ($name) = @_;
	$name =~ s/\0+\z//;
	my $base = $name;
	$base =~ s{.*/}{}s;
	return '' unless $base =~ /\./;
	$base =~ s{.*\.}{}s;
	return $base;
}

# Precompute the output sort key.  Directories get an empty leading field
# so they all sort ahead of every file (the 'F' marker below), ordered by
# full path; path order is prefix-respecting, so every parent directory
# precedes both its child directories and its files.  Without this a
# dot-directory such as .gnupg (whose basename looks like it has an
# "extension") could sort after files it contains, and the kernel would
# skip those files.  The remaining entries are ordered by extension, then
# by descending size (a zero-padded complement of the size, so the largest
# payloads come first), then by name.
my %sort_key;
for my $filename (keys %entries)
{
	if (is_dir($entries{$filename}))
	{
		$sort_key{$filename} = join "\0", '', $filename;
		next;
	}

	my $filesize = hex substr($entries{$filename}, 6 + 48, 8);
	$sort_key{$filename} = join "\0",
		'F',
		entry_ext($filename),
		sprintf("%08x", 0xFFFFFFFF - $filesize),
		$filename;
}
my @order = sort { $sort_key{$a} cmp $sort_key{$b} } keys %entries;

# Apply the cleaning to each one
for my $filename (@order)
{
	my $entry = $entries{$filename};
	my $zero = sprintf "%08x", 0;

	# inode is zeroed; safe because nlink is zero (see header)
	substr($entry, 6 + 0, 8) = $zero;

	# set timestamps to zero
	substr($entry, 6 + 40, 8) = $zero;

	# remove group/user permissions, leaving only
	# the owner bits intact.
	my $mode = hex substr($entry, 6 + 8, 8);
	$mode &= ~0077;
	#$mode |= $mode >> 3 | $mode >> 6;
	substr($entry, 6 + 8, 8) = sprintf "%08X", $mode;

	# set uid/gid to zero
	substr($entry, 6 + 16, 8) = $zero;
	substr($entry, 6 + 24, 8) = $zero;

	# zero out the nlinks, since it is managed by the real fs
	substr($entry, 6 + 32, 8) = $zero;

	# set the device major/minor to zero
	substr($entry, 6 + 56, 8) = $zero;
	substr($entry, 6 + 64, 8) = $zero;

	# set check to zero
	substr($entry, 6 + 96, 8) = $zero;

	$entries{$filename} = $entry;
}


# Output them in the precomputed (extension, size, name) order
my $out = join '', map { $entries{$_} } @order;

# Output the trailer to mark the end of the archive
$out .= $trailer;

# Pad to 512-bytes for kernel initrd reasons
my $unaligned = length($out) % 512;
$out .= chr(0x00) x (512 - $unaligned)
	if $unaligned != 0;

print $out;
__END__
