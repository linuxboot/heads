#!/bin/bash

set -exuo pipefail

targets="x230-hotp-maximized t430-hotp-maximized nitropad-nv41 nitropad-ns50"

version=$(git describe --dirty)


# prepare
./blobs/xx30/download_clean_me.sh -m $(readlink -f ./blobs/xx30/me_cleaner.py)

rm -rf artifacts
mkdir -p artifacts

for target in $targets
do

	rm -rf build/x86/log
	rm -rf build/x86/$target
	
	make BOARD=$target

	mytarget=$(echo $target | sed -e 's/hotp-maximized/maximized/g' | sed -e 's/nitropad-//g')


	cp build/x86/${target}/nitrokey-${target}-${version}.zip artifacts/firmware-nitropad-${mytarget}-${version}.zip
	cp build/x86/${target}/nitrokey-${target}-${version}.rom artifacts/firmware-nitropad-${mytarget}-${version}.rom
	
	# assemble "old style" .npf from new .zip format for backwards compatibility
	rm -rf /tmp/heads/
	mkdir -p /tmp/heads/
	cp artifacts/firmware-nitropad-${mytarget}-${version}.zip /tmp/heads
	cd /tmp/heads
	unzip firmware-nitropad-${mytarget}-${version}.zip
	sed -ie 's@  @  /tmp/verified_rom/@g' sha256sum.txt
	zip firmware-nitropad-${mytarget}-${version}.npf nitrokey-${target}-${version}.rom sha256sum.txt
	cd -
	cp /tmp/heads/firmware-nitropad-${mytarget}-${version}.npf artifacts


	if [[ "$target" = "t430-hotp-maximized" ]] || [[ "$target" = "x230-hotp-maximized" ]]; then

		cp build/x86/${target}/heads-${target}-${version}-top.rom artifacts/firmware-nitropad-${mytarget}-${version}-top.rom
		cp build/x86/${target}/heads-${target}-${version}-bottom.rom artifacts/firmware-nitropad-${mytarget}-${version}-bottom.rom

	fi

done
	
cd artifacts
sha256sum * > sha256sum
cd ..	






