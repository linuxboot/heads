To build for X220 we need to have the following files in this folder:
* `me.bin` - ME binary that has been stripped and truncated with me7_update_parser
* `gbe.bin` - Network card blob from the original firmware
* `ifd.bin` - Flash layout file has been provided as text

The ME blobs dumped in this directory come from the following link: https://pcsupport.lenovo.com/us/en/products/laptops-and-netbooks/thinkpad-x-series-laptops/thinkpad-x220/downloads/driver-list/component?name=Chipset

This provides latest ME version 7.1.91.3272, for which only the BUP region will be kept as non-removable:
Here is what Lenovo provides as a Summary of Changes:
<7.1.91.3272> (83RF46WW)
- (Fix) Fixed CVE-2017-5689: Escalation of privilege vulnerability in Intel(R)
        Active Management Technology (AMT), Intel(R) Standard Manageability
       (ISM), and Intel(R) Small Business Technology.


1.0:Automatically extract and neuter me update then add partition table to me.bin
download_parse_me.sh : Downloads latest ME update from lenovo verify checksum, extract ME, neuters ME, add partition table relocate and trim it and place it into me.bin

sha256sum:
1eef6716aa61dd844d58eca15a85faa1bf5f82715defd30bd3373e79ca1a3339  blobs/xx20/me.bin


1.1: Manually generating blobs
--------------------
Manually generate me.bin:
You can arrive to the same result of the following me.bin by doing the following manually:
wget  https://download.lenovo.com/ibmdl/pub/pc/pccbbs/mobiles/83rf46ww.exe && innoextract 83rf46ww.exe && python3 blobs/xx20/me7_update_parser.py -O blobs/xx20/me.bin app/ME7_5M_UPD_Production.bin

sha256sums:
48f18d49f3c7c79fa549a980f14688bc27c18645f64d9b6827a15ef5c547d210  83rf46ww.exe
760b0776b99ba94f56121d67c1f1226c77f48bd3b0799e1357a51842c79d3d36  app/ME7_5M_UPD_Production.bin
1eef6716aa61dd844d58eca15a85faa1bf5f82715defd30bd3373e79ca1a3339  blobs/xx20/me.bin

ifd.bin is from an X220 and already ME partition resided to the new minimized size.  The layout.txt has these updated sized and can be used with ifdtool to modify partition if needed.

sha256sum:
c96d19bbf5356b2b827e1ef52d79d0010884bfc889eab48835e4af9a634d129b  ifd.bin

ls -al blobs/xx20/*.bin
-rw-r--r-- 1 tom users  8192 Nov 23 18:40 gbe.bin
-rw-r--r-- 1 tom users  4096 Nov 23 18:58 ifd.bin
-rw-r--r-- 1 tom users 86016 Nov 26 17:04 me.bin

Manually regenerate gbe.bin:
blobs/x220/gbe.bin is generated per bincfg from the following coreboot patch: https://review.coreboot.org/c/coreboot/+/44510
And then by following those instructions:
# Use this target to generate GbE for X220/x230
gen-gbe-82579LM:
	cd build/coreboot-4.8.1/util/bincfg/
	make
	./bincfg gbe-82579LM.spec gbe-82579LM.set gbe1.bin
	# duplicate binary as per spec
	cat gbe1.bin gbe1.bin > ../../../../blobs/xx20/gbe.bin
	rm -f gbe1.bin
	cd -

sha256sum:
9f72818e23290fb661e7899c953de2eb4cea96ff067b36348b3d061fd13366e5  blobs/xx20/gbe.bin
------------------------
