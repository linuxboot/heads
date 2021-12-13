#!/bin/bash

sudo apt update
sudo apt install -y wget ruby ruby-dev ruby-bundler p7zip-full upx-ucl 

git clone https://github.com/awilliam/rom-parser.git
cd rom-parser
make
sudo cp rom-parser /usr/sbin/
cd ..
sudo rm -r rom-parser

wget https://github.com/LongSoft/UEFITool/releases/download/A58/UEFIExtract_NE_A58_linux_x86_64.zip
unzip UEFIExtract_NE_A58_linux_x86_64.zip
sudo mv UEFIExtract /usr/sbin/
rm UEFIExtract_NE_A58_linux_x86_64.zip

git clone https://github.com/coderobe/VBiosFinder.git
cd VBiosFinder
bundle install --path=vendor/bundle
wget https://download.lenovo.com/pccbbs/mobiles/g5uj39us.exe -P /home/$USER/
./vbiosfinder extract /home/$USER/g5uj39us.exe
rm /home/$USER/g5uj39us.exe
cd output
mv vbios_10de_0ffb_1.rom ../../10de,0ffb.rom
mv vbios_10de_0ffc_1.rom ../../10de,0ffc.rom
mv vbios_8086_0106_1.rom ../../8086,0106.rom
cd ..
cd ..
sudo rm -r VBiosFinder

