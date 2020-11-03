**Make sure that the binary files are backed up some where.**

Use the bdv file to get the pin layout and the location of the SOIC-8 chip on your board.
[Open Board View](https://github.com/OpenBoardView/OpenBoardView/releases) is a tool to read bdv files.

If you do not want to use the extract.sh script for blob extraction, you can also extract the blobs with _dd_:
```
$ dd if=eprom_read_1.bin of=gbe.bin skip=8 count=16
$ dd if=eprom_read_1.bin of=me.bin skip=24 count=10216
```
