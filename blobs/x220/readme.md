To build for X220 we need to have the following files in this folder:
* `me.bin` - ME binary that has been stripped and truncated with me_cleaner
* `gbe.bin` - Network card blob from the original firmware
* `ifd.bin` - Flash layout file has been provided as text

To get the binaries, start with a copy of the original Lenovo firmware image.
If you do not have one already, you can read one out from the laptops SPI flash.

```
flashrom --programmer internal:laptop=force_I_want_a_brick -r original.bin
```

Once you have the image, the provided extraction script will extract the files needed.

```
./extract.sh -f <romdump>
```

Use the options '-m' and '-i' to provide me_cleaner and ifdtool if they can not be located
automatically.

The flash layout will be automatically adjusted and the ME image cleaned and truncated.

You can now compile the image with:

make BOARD=x220 CONFIG=config/x220-generic.config
