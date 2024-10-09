This blobs/optiplex_9010/ifd.bin is a configuration blob, and comes from my optiplex 9010 backup.
It was put in place with:

python ~/me_cleaner/me_cleaner.py -S -r -t -d -O /tmp/discarded.bin -D ~/heads/blobs/optiplex_9010/ifd.bin -M /tmp/temporary_me.bin optiplex_9010-internal_backup.rom
./build/x86/coreboot-24.02.01/util/ifdtool/ifdtool -n blobs/optiplex_9010/layout.txt blobs/optiplex_9010/ifd.bin -O blobs/optiplex_9010/ifd.bin

NOTE: We rely on blobs/optiplex_9010/layout.txt which changes the size of the ME region to match Lenovo xx30 blob used in x230 and others.

----

blobs/optiplex_9010/ifd_t16650.bin comes from https://codeberg.org/libreboot/lbmk/src/branch/master/config/ifd/t1650/12_ifd
Libreboot uses xx30 ME (downloaded from Lenovo, extracted+ neutered) as well, and reuses the dell t1650 IFD for their build, which we borrowed here with:

wget https://codeberg.org/libreboot/lbmk/raw/branch/master/config/ifd/t1650/12_ifd -O ifd.bin

Doc: https://libreboot.org/docs/install/dell7010.html
