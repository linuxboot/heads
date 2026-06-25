# Use Suzy-Q cable for flashing

1. Connect the USB-C end of the Suzy-Q cable to the CCD port on your ChromeOS device 
   (usually left USB-C port) and the USB-A end to your Linux device
   Verify the cable is properly connected:
   * ls /dev/ttyUSB*
   * This command should return 3 items: ttyUSB0, ttyUSB1, and ttyUSB2.
   * If not, then your cable is connected to the wrong port or is upside down.
     Adjust and repeat command until output is as expected.

2. Set the CCD state to open:
   * echo "ccd open" | sudo tee -a /dev/ttyUSB0 > /dev/null

3. Test Connection and detect chip. `raiden_debug_spi` used from mrchromebox [doc](https://docs.mrchromebox.tech/docs/support/unbricking/unbrick-suzyq.html#persisting-the-board-s-vital-product-data-vpd-and-hardware-id-hwid)
   * sudo flashrom -p raiden_debug_spi
     ```
     ╚═ $ sudo flashrom -p raiden_debug_spi
     flashrom v1.6.0 on Linux 7.0.10+deb14-amd64 (x86_64)
     flashrom is free software, get the source code at https://flashrom.org

     FISK: (null)
     Raiden target: 0,0
     Raiden: Target SPI bridge is disabled (is WP enabled?)
     Raiden: Error configuring protocol
         protocol       = 2
         status         = 0x00005
     Error: Programmer initialization failed.
     ```
   * sudo flashrom -p raiden_debug_spi:target=AP casued a reboot.
     ```
      ╚═ $ sudo flashrom -p raiden_debug_spi:target=AP
     flashrom v1.6.0 on Linux 7.0.10+deb14-amd64 (x86_64)
     flashrom is free software, get the source code at https://flashrom.org

     FISK: AP
     Raiden target: 2,0
     Found Winbond flash chip "W25Q256JV_M" (32768 kB, SPI) on raiden_debug_spi.
     No operations were specified.
     ```

4. Create backup, and verify.
   * sudo flashrom -p raiden_debug_spi:target=AP -r badflash.rom
   * hexdump -C badflash.rom | head -20
       ```
         00000000  11 00 00 9c 90 02 00 d6  00 00 00 05 ff ff ff ff  |................|
         00000010  5a a5 f0 0f 03 00 04 00  08 02 10 46 b0 01 14 00  |Z..........F....|
         00000020  00 00 00 00 ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
         00000030  f6 30 30 09 21 42 60 ad  b7 b9 c4 c7 ff ff ff ff  |.00.!B`.........|
         00000040  00 00 00 00 00 05 ff 1f  01 00 ff 04 ff 7f 00 00  |................|
         00000050  ff 7f 00 00 ff 7f 00 00  ff 7f 00 00 ff 7f 00 00  |................|
         *
         00000080  00 07 20 00 00 05 40 00  00 00 00 00 00 00 00 00  |.. ...@.........|
         00000090  00 00 00 00 00 00 00 00  ff ff ff ff ff ff ff ff  |................|
         000000a0  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
         *
         00000100  00 00 00 00 01 00 00 00  09 00 04 00 00 ce 3d 03  |..............=.|
         00000110  7f 00 38 00 00 00 00 00  10 00 00 00 02 00 20 60  |..8........... `|
         00000120  08 30 03 48 00 00 00 00  01 00 7f 0f 82 0b c0 04  |.0.H............|
         00000130  00 00 00 00 00 00 0e 00  22 42 22 42 22 22 42 22  |........"B"B""B"|
         00000140  00 00 00 00 00 00 00 00  00 00 ff 00 60 00 80 c8  |............`...|
         00000150  45 86 00 36 01 00 a6 81  20 0e 58 00 01 00 40 00  |E..6.... .X...@.|
         00000160  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
         00000170  00 1c 00 00 00 00 00 00  54 b3 04 a0 30 00 00 41  |........T...0..A|
         00000180  8f 03 08 c6 00 01 00 00  00 00 00 00 00 00 00 00  |................|
       ```
   * sudo flashrom -p raiden_debug_spi:target=AP --verify badflash.rom
       ```
    	 flashrom v1.6.0 on Linux 7.0.10+deb14-amd64 (x86_64)
		 flashrom is free software, get the source code at https://flashrom.org

		 FISK: AP
		 Raiden target: 2,0
		 Found Winbond flash chip "W25Q256JV_M" (32768 kB, SPI) on raiden_debug_spi.
		 Verifying flash... FAILED at 0x01bbeadb! Expected=0x94, Found=0xb4, failed byte count from 0x00000000-0x01ffffff: 0x3f
       ```

5. Created a backup and verify it using heads wiki guide.
   * sudo flashrom -p raiden_debug_spi:target=AP --read backup.bin --chip "W25Q256JV_M"
   * sudo flashrom -p raiden_debug_spi:target=AP --verify backup.bin --chip "W25Q256JV_M"
       ```
       ╚═ $ sudo flashrom -p raiden_debug_spi:target=AP --verify backup.bin --chip "W25Q256JV_M"
      flashrom v1.6.0 on Linux 7.0.10+deb14-amd64 (x86_64)
      flashrom is free software, get the source code at https://flashrom.org

      FISK: AP
      Raiden target: 2,0
      Found Winbond flash chip "W25Q256JV_M" (32768 kB, SPI) on raiden_debug_spi.
      Verifying flash... FAILED at 0x01bc9254! Expected=0xb7, Found=0xb8, failed byte count from 0x00000000-0x01ffffff: 0x3e
       ```
6. Disconnect Battery to disable write-protection.
  * Remove The 9 screws.
  <img of screws>
  * Use a smudger to take the back cover off.
  * Disconnect battery cable.
  <img of battery connector>

7. Disable write-protection. [mrchromebox guide](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html)
  * Plug laptop into power.
  * Plug in suzy-q cable.
  * echo "wp false" > /dev/ttyUSB0
  * echo "wp false atboot" > /dev/ttyUSB0
  * echo "ccd reset factory" > /dev/ttyUSB0
