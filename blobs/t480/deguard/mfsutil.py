#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only
# This code is based on MFSUtil by Youness Alaoui (see `doc/LICENSE.orig` for original copyright)

import sys, argparse, textwrap
from lib.mfs import MFS
from lib.cfg import CFG
import zipfile, posixpath

def main():
  parser = argparse.ArgumentParser(description='MFS and CFG file manipulation utility.',
                                   formatter_class=argparse.RawDescriptionHelpFormatter,
                                   epilog="""
The default output is to stdout.
Either one of --mfs or --cfg must be specified to indicate on which \
type of file to work (MFS or CFG).
You can specify one of the mutually exclusive actions : \
--dump --zip, --extract, --add, --remove.
For the --extract, --add, --remove actions, if --mfs is specified, \
then --file-id is required, if --cfg is specified, then --file-path is required.
When adding a file to a CFG file, the --mode, --opt, --uid and --gid options can be added.
The --mode option needs to be a string in the form 'dAEIrwxrwxrwx' where \
unused bits can be either a space or a dash, like --mode '    rwx---rwx' for example.
The --opt option needs to be a string in the form '?!MF' where unused bits can be \
either a space or a dash.
When adding a directory, both the file path needs to end with a '/' character and the --mode needs to start with 'd'.
""")

  parser.add_argument("-o", "--output", dest="output", default='-',
                      help="Output file to write", metavar="FILE")
  parser.add_argument("-i", "--file-id", dest="file_id", type=int,
                      help="ID of the file to manipulate in the MFS file", metavar="ID")
  parser.add_argument("-f", "--file-path", dest="file_path",
                      help="Path of the file to manipulate in the CFG file", metavar="PATH")
  parser.add_argument("--mode", dest="mode", default="---rwxrwxrwx",
                      help="Mode for file being added to CFG", metavar="MODE")
  parser.add_argument("--opt", dest="opt", default="----",
                      help="Deplyoment option for file being added to CFG", metavar="OPT")
  parser.add_argument("--uid", dest="uid", default=0, type=int,
                      help="User ID for file being added to CFG", metavar="UID")
  parser.add_argument("--gid", dest="gid", default=0, type=int,
                      help="Group ID for file being added to CFG", metavar="GID")
  parser.add_argument("--recursive", dest="recursive", action="store_true",
                      help="Recursive deletion for a file path in CFG")
  parser.add_argument("--alignment", dest="alignment", type=int, default=0,
                      help="Alignment type for CFG files. (default: 0).\n"
                      "0 : packed.\n"
                      "1 : align all files on chunk start.\n"
                      "2 : align end of files on end of chunk.")
  parser.add_argument("--deoptimize", dest="optimize", action="store_false",
                      help="De-optimize chain sequences when adding a file to MFS.")
  
  group = parser.add_mutually_exclusive_group(required=True)
  group.add_argument("-m", "--mfs", dest="mfs", type=argparse.FileType('rb'),
                     help="MFS file to read from", metavar="FILE")
  group.add_argument("-c", "--cfg", dest="cfg", type=argparse.FileType('rb'),
                     help="CFG file to read from", metavar="FILE")

  group = parser.add_mutually_exclusive_group(required=True)
  group.add_argument("-d", "--dump", dest='dump', action="store_true",
                     help="Dump information about the MFS file, or the CFG file")
  group.add_argument("-z", "--zip", dest='zip', action="store_true",
                     help="Store the MFS contents to a ZIP file")
  group.add_argument("-x", "--extract", dest='extract', action="store_true",
                     help="Extract a file from the MFS file, or a file from the CFG file")
  group.add_argument("-a", "--add", dest='add', type=argparse.FileType('rb'),
                     help="Add a file to the MFS file or a file to the CFG file",
                     metavar="FILENAME")
  group.add_argument("-r", "--remove", dest='remove', action="store_true",
                     help="Remove a file from the MFS file, or a file from the CFG file")
  args = parser.parse_args()
    
  if (args.add or args.remove or args.extract) and (args.cfg and args.file_path is None):
    parser.error("--add/--remove/--extract on a --cfg file requires the --file-path option")
  if (args.add or args.remove or args.extract) and (args.mfs and args.file_id is None):
    parser.error("--add/--remove/--extract on a --mfs file requires the --file-id option")

  if args.mfs is not None:
    data = args.mfs.read()
    mfs = MFS(data)

    if args.dump:
      with argparse.FileType("wb")(args.output) as f: f.write("%s" % mfs)
    elif args.extract:
      file = mfs.getSystemVolume().getFile(args.file_id)
      if file:
        with argparse.FileType("wb")(args.output) as f: f.write(file.data)
      else:
        print("File ID %d does not exist in the MFS System Volume" % args.file_id)
        sys.exit(-1)
    elif args.remove:
      mfs.getSystemVolume().removeFile(args.file_id)
      mfs.generate()
      with argparse.FileType("wb")(args.output) as f: f.write(mfs.data)
    elif args.add:
      file = mfs.getSystemVolume().getFile(args.file_id)
      if file:
        print("File ID %d already exists in the MFS System Volume" % args.file_id)
        sys.exit(-1)
      data = args.add.read()
      mfs.getSystemVolume().addFile(args.file_id, data, args.optimize)
      mfs.generate()
      with argparse.FileType("wb")(args.output) as f: f.write(mfs.data)
    elif args.zip:
      z = zipfile.ZipFile(args.output, "w", zipfile.ZIP_STORED)
      for id in xrange(mfs.getSystemVolume().numFiles):
        file = mfs.getSystemVolume().getFile(id)
        if file:
          zi = zipfile.ZipInfo("file_%d.bin" % id)
          zi.external_attr = (0o644 << 16)
          z.writestr(zi, file.data)
      z.close()
  else:
    data = args.cfg.read()
    cfg = CFG(data)
    if args.dump:
      with argparse.FileType("wb")(args.output) as f: f.write("%s" % cfg)
      cfg.generate(args.alignment)
      #with argparse.FileType("wb")(args.output) as f: f.write(cfg.data)
      assert cfg.data == data
    elif args.zip:
      z = zipfile.ZipFile(args.output, "w", zipfile.ZIP_STORED)
      for file in cfg.files:
        path = file.path
        if file.isDirectory():
          path += posixpath.sep
          attr = (0o40755 << 16) | 0x30
        else:
          attr = (0o644 << 16)
        zi = zipfile.ZipInfo(path)
        zi.external_attr = attr
        z.writestr(zi, file.data)
      z.close()
    elif args.extract:
      file = cfg.getFile(args.file_path)
      if file is None:
        print("File path '%s' does not exist in the CFG file" % args.file_path)
        sys.exit(-1)
      with argparse.FileType("wb")(args.output) as f: f.write(file.data)
    elif args.remove:
      res = cfg.removeFile(args.file_path, args.recursive)
      if not res:
        if cfg.getFile(args.file_path) is None:
          print("File path '%s' does not exist in the CFG file" % args.file_path)
        else:
          print("File path '%s' is a non-empty directory in the CFG file (use --recursive)" % args.file_path)
        sys.exit(-1)
      cfg.generate(args.alignment)
      with argparse.FileType("wb")(args.output) as f: f.write(cfg.data)
    elif args.add:
      file = cfg.getFile(args.file_path)
      if file:
        print("File path '%s' already exists in the CFG file" % args.file_path)
        sys.exit(-1)
      data = args.add.read()
      mode = CFG.strToMode(args.mode)
      opt = CFG.strToOpt(args.opt)
      if args.file_path[-1] == '/':
        assert mode & 0x1000 == 0x1000
      else:
        assert mode & 0x1000 == 0
        
      if not cfg.addFile(args.file_path, data, mode, opt, args.uid, args.gid):
        print("Error adding file to path '%s' in the CFG file " \
          "(parent doesn't exist or is not a directory?)" % args.file_path)
        sys.exit(-1)
      cfg.generate(args.alignment)
      with argparse.FileType("wb")(args.output) as f: f.write(cfg.data)
      
        

if __name__=="__main__":
  main()
