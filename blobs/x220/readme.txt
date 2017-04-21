To build for X220 we need to have the following files in this folder:
me.bin - ME binary that has been stripped and truncated with me_cleaner
gbe.bin - Network card blob from the original firmware
ifd.bin - Flash layout file has been provided, layout.txt is also present for changes

To get the binaries, start with a copy of the original lenovo firmware image.
If you do not have one already, you can read one out from the laptops SPI flash.

flashrom --programmer internal:laptop=force_I_want_a_brick -r original.bin

Once you have the image, run ifdtool -x <bios image> to extract the parts.
Rename flashregion_3_gbe.bin to gbe.bin
Run "me_cleaner -r -t -O me.bin flashregion_2_intel_me.bin" to truncate and neuter
the ME blob.

You can now compile the image with:

make CONFIG=config/x220-qubes.conf
