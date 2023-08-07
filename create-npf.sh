#!/bin/bash
set -exuo pipefail
HEADS_GIT_VERSION=$(git describe --tags)
BOARD=$1
cd ./build/x86/${BOARD}/
sha256sum heads-${BOARD}-${HEADS_GIT_VERSION}.rom > sha256sum.txt
sed -ie 's@  @  /tmp/verified_rom/@g' sha256sum.txt
zip heads-${BOARD}-${HEADS_GIT_VERSION}.npf heads-${BOARD}-${HEADS_GIT_VERSION}.rom sha256sum.txt

# fake commit circleci
