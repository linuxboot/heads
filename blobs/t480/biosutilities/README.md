# BIOSUtilities [Refactor - WIP]
**Various BIOS Utilities for Modding/Research**

[BIOS Utilities News Feed](https://twitter.com/platomaniac)

* [**AMI BIOS Guard Extractor**](#ami-bios-guard-extractor)
* [**AMI UCP Update Extractor**](#ami-ucp-update-extractor)
* [**Apple EFI IM4P Splitter**](#apple-efi-im4p-splitter)
* [**Apple EFI Image Identifier**](#apple-efi-image-identifier)
* [**Apple EFI Package Extractor**](#apple-efi-package-extractor)
* [**Apple EFI PBZX Extractor**](#apple-efi-pbzx-extractor)
* [**Award BIOS Module Extractor**](#award-bios-module-extractor)
* [**Dell PFS Update Extractor**](#dell-pfs-update-extractor)
* [**Fujitsu SFX BIOS Extractor**](#fujitsu-sfx-bios-extractor)
* [**Fujitsu UPC BIOS Extractor**](#fujitsu-upc-bios-extractor)
* [**Insyde iFlash/iFdPacker Extractor**](#insyde-iflashifdpacker-extractor)
* [**Panasonic BIOS Package Extractor**](#panasonic-bios-package-extractor)
* [**Phoenix TDK Packer Extractor**](#phoenix-tdk-packer-extractor)
* [**Portwell EFI Update Extractor**](#portwell-efi-update-extractor)
* [**Toshiba BIOS COM Extractor**](#toshiba-bios-com-extractor)
* [**VAIO Packaging Manager Extractor**](#vaio-packaging-manager-extractor)

## **AMI BIOS Guard Extractor**

![]()

#### **Description**

Parses AMI BIOS Guard (a.k.a. PFAT, Platform Firmware Armoring Technology) images, extracts their SPI/BIOS/UEFI firmware components and decompiles the Intel BIOS Guard Scripts. It supports all AMI PFAT revisions and formats, including those with Index Information tables or nested AMI PFAT structures. The output comprises only final firmware components which are directly usable by end users.

Note that the AMI PFAT structure may not have an explicit component order. AMI's BIOS Guard Firmware Update Tool (AFUBGT) updates components based on the user/OEM provided Parameters and Options or Index Information table, when applicable. That means that merging all the components together does not usually yield a proper SPI/BIOS/UEFI image. The utility does generate such a merged file with the name "00 -- \<filename\>\_ALL.bin" but it is up to the end user to determine its usefulness. Moreover, any custom OEM data after the AMI PFAT structure are additionally stored in the last file with the name "\<n+1\> -- \_OOB.bin" and it is once again up to the end user to determine its usefulness. In cases where the trailing custom OEM data include a nested AMI PFAT structure, the utility will process and extract it automatically as well.

#### **Usage**

You can either Drag & Drop or manually enter AMI BIOS Guard (PFAT) image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

Optionally, to decompile the AMI PFAT \> Intel BIOS Guard Scripts, you must have the following 3rd party utility at the "external" project directory:

* [BIOS Guard Script Tool](https://github.com/platomav/BGScriptTool) (i.e. big_script_tool.py)

#### **Pictures**

![]()

## **AMI UCP Update Extractor**

![]()

#### **Description**

Parses AMI UCP (Utility Configuration Program) Update executables, extracts their firmware components (e.g. SPI/BIOS/UEFI, EC, ME etc) and shows all relevant info. It supports all AMI UCP revisions and formats, including those with nested AMI PFAT, AMI UCP or Insyde iFlash/iFdPacker structures. The output comprises only final firmware components and utilities which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter AMI UCP Update executable file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts
* -c or --checksum : verify AMI UCP Checksums (slow)

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tools at the "external" project directory:

* [TianoCompress](https://github.com/tianocore/edk2/tree/master/BaseTools/Source/C/TianoCompress/) (i.e. [TianoCompress.exe for Windows](https://github.com/tianocore/edk2-BaseTools-win32/) or TianoCompress for Linux)
* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

Optionally, to decompile the AMI UCP \> AMI PFAT \> Intel BIOS Guard Scripts (when applicable), you must have the following 3rd party utility at the "external" project directory:

* [BIOS Guard Script Tool](https://github.com/platomav/BGScriptTool) (i.e. big_script_tool.py)

#### **Pictures**

![]()

## **Apple EFI IM4P Splitter**

![]()

#### **Description**

Parses Apple IM4P multi-EFI files and splits all detected EFI firmware into separate Intel SPI/BIOS images. The output comprises only final firmware components and utilities which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Apple EFI IM4P file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you do not need any prerequisites.

#### **Pictures**

![]()

## **Apple EFI Image Identifier**

![]()

#### **Description**

Parses Apple EFI images and identifies them based on Intel's official $IBIOSI$ tag, which contains info such as Model, Version, Build, Date and Time. Optionally, the utility can rename the input Apple EFI image based on the retrieved $IBIOSI$ tag info, while also making sure to differentiate any EFI images with the same $IBIOSI$ tag (e.g. Production, Pre-Production) by appending a checksum of their data.

#### **Usage**

You can either Drag & Drop or manually enter Apple EFI image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts
* -r or --rename : rename EFI image based on its tag

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tools at the "external" project directory:

* [UEFIFind](https://github.com/LongSoft/UEFITool/) (i.e. [UEFIFind.exe for Windows or UEFIFind for Linux](https://github.com/LongSoft/UEFITool/releases))
* [UEFIExtract](https://github.com/LongSoft/UEFITool/) (i.e. [UEFIExtract.exe for Windows or UEFIExtract for Linux](https://github.com/LongSoft/UEFITool/releases))

#### **Pictures**

![]()

## **Apple EFI Package Extractor**

![]()

#### **Description**

Parses Apple EFI PKG firmware packages (i.e. FirmwareUpdate.pkg, BridgeOSUpdateCustomer.pkg), extracts their EFI images, splits those in IM4P format and identifies/renames the final Intel SPI/BIOS images accordingly. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Apple EFI PKG package file(s). Optional arguments:

* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tools at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()

## **Apple EFI PBZX Extractor**

![]()

#### **Description**

Parses Apple EFI PBZX images, re-assembles their CPIO payload and extracts its firmware components (e.g. IM4P, EFI, Utilities, Scripts etc). It supports CPIO re-assembly from both Raw and XZ compressed PBZX Chunks. The output comprises only final firmware components and utilities which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Apple EFI PBZX image file(s). Optional arguments:

* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tools at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()

## **Award BIOS Module Extractor**

![]()

#### **Description**

Parses Award BIOS images and extracts their modules (e.g. RAID, MEMINIT, \_EN_CODE, awardext etc). It supports all Award BIOS image revisions and formats, including those which contain LZH compressed files. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Award BIOS image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tool at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()

## **Dell PFS Update Extractor**

![]()

#### **Description**

Parses Dell PFS Update images and extracts their Firmware (e.g. SPI, BIOS/UEFI, EC, ME etc) and Utilities (e.g. Flasher etc) component sections. It supports all Dell PFS revisions and formats, including those which are originally LZMA compressed in ThinOS packages (PKG), ZLIB compressed or Intel BIOS Guard (PFAT) protected. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Dell PFS Update images(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts
* -a or --advanced : extract signatures and metadata
* -s or --structure : show PFS structure information

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

Optionally, to decompile the Intel BIOS Guard (PFAT) Scripts, you must have the following 3rd party utility at the "external" project directory:

* [BIOS Guard Script Tool](https://github.com/platomav/BGScriptTool) (i.e. big_script_tool.py)

#### **Pictures**

![]()

## **Fujitsu SFX BIOS Extractor**

![]()

#### **Description**

Parses Fujitsu SFX BIOS images and extracts their obfuscated Microsoft CAB archived firmware (e.g. SPI, BIOS/UEFI, EC, ME etc) and utilities (e.g. WinPhlash, PHLASH.INI etc) components. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Fujitsu SFX BIOS image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tool at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()

## **Fujitsu UPC BIOS Extractor**

![]()

#### **Description**

Parses Fujitsu UPC BIOS images and extracts their EFI compressed SPI/BIOS/UEFI firmware component. The output comprises only a final firmware component which is directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Fujitsu UPC BIOS image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tool at the "external" project directory:

* [TianoCompress](https://github.com/tianocore/edk2/tree/master/BaseTools/Source/C/TianoCompress/) (i.e. [TianoCompress.exe for Windows](https://github.com/tianocore/edk2-BaseTools-win32/) or TianoCompress for Linux)

#### **Pictures**

![]()

## **Insyde iFlash/iFdPacker Extractor**

![]()

#### **Description**

Parses Insyde iFlash/iFdPacker Update images and extracts their firmware (e.g. SPI, BIOS/UEFI, EC, ME etc) and utilities (e.g. InsydeFlash, H2OFFT, FlsHook, iscflash, platform.ini etc) components. It supports all Insyde iFlash/iFdPacker revisions and formats, including those which are 7-Zip SFX 7z compressed in raw, obfuscated or password-protected form. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Insyde iFlash/iFdPacker Update image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you do not need any prerequisites.

#### **Pictures**

![]()

## **Panasonic BIOS Package Extractor**

![]()

#### **Description**

Parses Panasonic BIOS Package executables and extracts their firmware (e.g. SPI, BIOS/UEFI, EC etc) and utilities (e.g. winprom, configuration etc) components. It supports all Panasonic BIOS Package revisions and formats, including those which contain LZNT1 compressed files. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Panasonic BIOS Package executable file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party Python modules installed:

* [pefile](https://pypi.org/project/pefile/)
* [lznt1](https://pypi.org/project/lznt1/)

Moreover, you must have the following 3rd party tool at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()

## **Phoenix TDK Packer Extractor**

![]()

#### **Description**

Parses Phoenix Tools Development Kit (TDK) Packer executables and extracts their firmware (e.g. SPI, BIOS/UEFI, EC etc) and utilities (e.g. WinFlash etc) components. It supports all Phoenix TDK Packer revisions and formats, including those which contain LZMA compressed files. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Phoenix Tools Development Kit (TDK) Packer executable file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party Python module installed:

* [pefile](https://pypi.org/project/pefile/)

#### **Pictures**

![]()

## **Portwell EFI Update Extractor**

![]()

#### **Description**

Parses Portwell UEFI Unpacker EFI executables (usually named "Update.efi") and extracts their firmware (e.g. SPI, BIOS/UEFI, EC etc) and utilities (e.g. Flasher etc) components. It supports all known Portwell UEFI Unpacker revisions (v1.1, v1.2, v2.0) and formats (used, empty, null), including those which contain EFI compressed files. The output comprises only final firmware components and utilities which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Portwell UEFI Unpacker EFI executable file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party Python module installed:

* [pefile](https://pypi.org/project/pefile/)

> pip3 install pefile

Moreover, you must have the following 3rd party tool at the "external" project directory:

* [TianoCompress](https://github.com/tianocore/edk2/tree/master/BaseTools/Source/C/TianoCompress/) (i.e. [TianoCompress.exe for Windows](https://github.com/tianocore/edk2-BaseTools-win32/) or TianoCompress for Linux)

#### **Pictures**

![]()

## **Toshiba BIOS COM Extractor**

![]()

#### **Description**

Parses Toshiba BIOS COM images and extracts their raw or compressed SPI/BIOS/UEFI firmware component. This utility is basically an easy to use python wrapper around [ToshibaComExtractor by LongSoft](https://github.com/LongSoft/ToshibaComExtractor). The output comprises only a final firmware component which is directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter Toshiba BIOS COM image file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tool at the "external" project directory:

* [ToshibaComExtractor](https://github.com/LongSoft/ToshibaComExtractor) (i.e. [comextract.exe for Windows or comextract for Linux](https://github.com/LongSoft/ToshibaComExtractor/releases))

#### **Pictures**

![]()

## **VAIO Packaging Manager Extractor**

![]()

#### **Description**

Parses VAIO Packaging Manager executables and extracts their firmware (e.g. SPI, BIOS/UEFI, EC, ME etc), utilities (e.g. WBFLASH etc) and driver (audio, video etc) components. If direct extraction fails, it attempts to unlock the executable in order to run at all non-VAIO systems and allow the user to choose the extraction location. It supports all VAIO Packaging Manager revisions and formats, including those which contain obfuscated Microsoft CAB archives or obfuscated unlock values. The output comprises only final firmware components which are directly usable by end users.

#### **Usage**

You can either Drag & Drop or manually enter VAIO Packaging Manager executable file(s). Optional arguments:
  
* -h or --help : show help message and exit
* -v or --version : show utility name and version
* -i or --input-dir : extract from given input directory
* -o or --output-dir : extract in given output directory
* -e or --auto-exit : skip all user action prompts

#### **Compatibility**

Should work at all Windows, Linux or macOS operating systems which have Python 3.10 support.

#### **Prerequisites**

To run the utility, you must have the following 3rd party tool at the "external" project directory:

* [7-Zip Console](https://www.7-zip.org/) (i.e. 7z.exe for Windows or 7zzs for Linux)

#### **Pictures**

![]()