#!/bin/sh

flashrom \
	--force \
	--noverify \
	--programmer internal \
	--layout /etc/x230-layout.txt \
	--image BIOS \
	-w "$*"
