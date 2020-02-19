To build for T420, we need to have the following files in this folder:
* `me.bin` - ME binary that has been stripped and truncated with me_cleaner
* `gbe.bin` - Network card blob from the original firmware
* `ifd.bin` - Flash layout file has been provided as text

To get the binaries, start with a copy of the original Lenovo firmware image.
If you do not have one already, you can read one out from the laptops SPI flash with flashrom

```
flashrom -p <programmer> -r original.bin
```

Set `<programmer>` to the flashrom programmer type that you will use (for example, `linux_spi:dev=/dev/spidev0.0` on a Raspberry Pi).

Once you have the image, the provided extraction script will extract the files needed.

```
./extract.sh -f <romdump>
```

Use the options '-m' and '-i' to provide me_cleaner and ifdtool if they can not be located automatically.

The flash layout will be automatically adjusted and the ME image cleaned and truncated.

You can now compile the image with:

```
make BOARD=t420
```
