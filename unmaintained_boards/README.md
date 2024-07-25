Boards listed under this directory are not made available from CircleCI. No .rom file is available for endusers. This is protecting as good as possible regular endusers from having to open up their devices and having to own a SPI-clip and a external flasher.
After core changes in coreboot or heads, known testers with external flasher are asked to test a new release and report if their system is starting up fine. If those known testers do not respond, a .rom id made available from CircleCI to the public with addition in filename UNTESTED_ . This invite people with external flasher that could recover a not booting system to report if the release is working fine.
Warning: Do not try to use UNTESTED_ images if you do not have a external flasher.

After about a month passes by and there is still no report if the system is starting up fine with the new release, the device is moved to this directory to stop building UNTESTED_ images. Reason for this is because there are always users ignoring all warnings and then asking questions like how to recover a not starting system without external programmer.

To get a device out of this directory and make it at available from CircleCI again, open up a issue here https://github.com/linuxboot/heads/issues and ask for a build for the specific device you like to test or build it youself. When building it yourself, please dont forget to report a working state.

The additional name UNMAINTAINED_ is added to the device name, when maintanance is known needed.
When device is UNTESTED_ and someone test and report a not booting image, the device get as soon as possibe moved to this directory and changed from UNTESTED_ to UNMAINTAINED_. Its then tested and not working.

When a device have just the addition UNMAINTAINED_ but is not in this directory and there are CircleCI .rom files available to the endusers, then its tested starting up the system but have some problems like for example not working Network card and there is no maintainer to fix the problem.
If a UNMAINTAINED_ device dont get tested on a new release, it follow up the same UNTESTED_ procedure like described above and have UNMAINTAINED_UNTESTED_ in the name.
