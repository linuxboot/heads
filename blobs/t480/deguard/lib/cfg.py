# SPDX-License-Identifier: GPL-2.0-only
# This code is based on MFSUtil by Youness Alaoui (see `doc/LICENSE.orig` for original copyright)

import posixpath
import struct
from functools import cmp_to_key

def cmp(a, b):
		return (a > b) - (a < b)

class CFGAlignment:
	ALIGN_NONE = 0
	ALIGN_START = 1
	ALIGN_END = 2

class CFG(object):
	CFG_FMT = struct.Struct("<L")

	def __init__(self, data=None):
		self.files = []
		if data:
			self.data = data
			self.num_records, = self.CFG_FMT.unpack_from(self.data)
			self.records = []

			data_offset = self.CFG_FMT.size + (self.num_records * CFGRecord.RECORD_FMT.size)
			total_data = 0
			path = ["/"]
			parent = None
			for i in range(self.num_records):
					record = CFGRecord(self.data, i)
					#assert (record.isDirectory() and record.offset == data_offset) or \
					#  (not record.isDirectory() and record.offset == data_offset + total_data)
					total_data += record.size
					if record.name == "..":
						assert len(path) > 1
						file = self.getFile(posixpath.join(*path))
						assert file and file.isDirectory()
						assert file.record.mode == record.mode
						path.pop()
					else:
						file = CFGFile(posixpath.join(*path + [record.name]), record, self.data, parent)
						self.files.append(file)
						if record.isDirectory():
							path.append(record.name)
					parent = self.getFile(posixpath.join(*path))
					self.records.append(record)

	def getFile(self, path):
		for file in self.files:
			if file.path == path:
				return file
		return None

	def removeFile(self, path, recursive = False):
		file = self.getFile(path)
		if file:
			if len(file.children) > 0 and not recursive:
				return False
			# Copy list of children since we're modifying the list
			for child in file.children[:]:
				self.removeFile(child.path, recursive)
			self.files.remove(file)
			if file.parent:
				file.parent.removeChild(file)
			return True
		else:
			return False

	def addFile(self, path, data, mode, opt, uid, gid):
		# Make sure it doesn't already exists
		file = self.getFile(path)
		if file:
			raise ValueError(f"CFG path {path} already exists")

		directory = False
		(parent_path, filename) = posixpath.split(path)

		if filename == "":
			directory = True
			(parent_path, filename) = posixpath.split(parent_path)

		# Make sure parent exists if it is not the root
		parent = self.getFile(parent_path)
		if parent_path != "/"and parent is None:
			raise ValueError(f"CFG path {path} already exists")

		record = CFGRecord.createRecord(filename, mode, opt, uid, gid, len(data), 0)
		file = CFGFile(path, record, data, parent)
		self.files.append(file)

	def generate(self, alignment):
		self.records = []
		file_data = b""
		if len(self.files) > 0:
			(self.records, file_data) = self.files[0].generateRecords(alignment=alignment)
		self.num_records = len(self.records)
		self.data = self.CFG_FMT.pack(self.num_records)
		data_offset = len(self.data) + CFGRecord.RECORD_FMT.size * self.num_records
		alignment_data = b""
		if alignment != CFGAlignment.ALIGN_NONE:
			alignment_extra = data_offset % 0x40
			if alignment_extra > 0:
					alignment_data += struct.pack("<B", 0) * (0x40 - alignment_extra)
					data_offset += 0x40 - alignment_extra
		data_size = 0
		for record in self.records:
			record.offset += data_offset
			record.generate()
			self.data += record.data
		self.data += alignment_data
		self.data += file_data

	def __str__(self):
		ret = "Number of records : %d\n" % self.num_records
		path = ["/"]
		for record in self.records:
			ret += "%s %s\n" % (str(record), posixpath.join(*path + ([] if record.name == ".." else [record.name])))
			if record.name == "..":
				path.pop()
			elif record.isDirectory():
				path.append(record.name)

		return ret

	@staticmethod
	def modeToStr(mode):
		assert mode & 0xE000 == 0
		modeStr = "dAEIrwxrwxrwx"
		ret = ""
		for i in range(13):
			if mode & (0x1000 >> i):
				ret += modeStr[i]
			else:
				ret += "-"
		return ret

	@staticmethod
	def strToMode(str):
		modeStr = "dAEIrwxrwxrwx"
		assert len(str) == len(modeStr)
		mode = 0
		for i in range(13):
			if str[i] == modeStr[i]:
				mode |= (0x1000 >> i)
			else:
				assert str[i] == '-' or str[i] == ' '
		return mode

	@staticmethod
	def optToStr(opt):
		assert opt & 0xFFF0 == 0
		optStr = "?!MF"
		ret = ""
		for i in range(4):
			if opt & (8 >> i):
				ret += optStr[i]
			else:
				ret += "-"
		return ret

	@staticmethod
	def strToOpt(str):
		optStr = "?!MF"
		assert len(str) == len(optStr)
		opt = 0
		for i in range(4):
			if str[i] == optStr[i]:
				opt |= (8 >> i)
			else:
				assert str[i] == '-' or str[i] == ' '
		return opt

class CFGRecord(object):
	RECORD_FMT = struct.Struct("<12sHHHHHHL")

	def __init__(self, data, index):
			offset = CFG.CFG_FMT.size + self.RECORD_FMT.size * index
			self.data = data[offset:offset + self.RECORD_FMT.size]
			(self.name, zero, self.mode, self.opt, self.size,
			 self.uid, self.gid, self.offset) = self.RECORD_FMT.unpack(self.data)
			self.name = self.name.decode('utf-8')
			self.name = self.name.strip('\0')
			if self.name == "..":
				assert self.isDirectory()
				assert self.opt == 0
			if self.isDirectory():
				assert self.size == 0

	def isDirectory(self):
		return self.mode & 0x1000 == 0x1000

	def generate(self):
		self.data = CFGRecord.RECORD_FMT.pack(self.name.encode("utf-8"), 0, self.mode, self.opt,
			self.size, self.uid, self.gid, self.offset)

	@staticmethod
	def createRecord(name, mode, opt, uid, gid, size, offset):
		data = b'\0' * CFG.CFG_FMT.size + \
			CFGRecord.RECORD_FMT.pack(name.encode("utf-8"), 0, mode, opt, size, uid, gid, offset)
		return CFGRecord(data, 0)

	def copy(self):
		return self.createRecord(self.name, self.mode, self.opt, self.uid, self.gid, self.size, self.offset)

	def __str__(self):
		return "%-12s (%04X:%04X) [%4d bytes @ %8X] %s _ %s" % (self.name, self.uid, self.gid,
			self.size, self.offset, CFG.modeToStr(self.mode), CFG.optToStr(self.opt))

class CFGFile(object):
	def __init__(self, path, record, data, parent=None):
		self.path = path
		self.record = record
		self.data = data[record.offset:record.offset + record.size]
		self.parent = parent
		self.children = []
		if parent:
			parent.addChild(self)

	@property
	def size(self):
		return self.record.size

	def isDirectory(self):
		return self.record.isDirectory()

	def addChild(self, child):
		assert self.isDirectory()
		self.children.append(child)
		self.children.sort(key=cmp_to_key(CFGFile.__cmp__))

	def removeChild(self, child):
		assert self.isDirectory() and child in self.children
		self.children.remove(child)

	def generateRecords(self, data = b"", alignment=CFGAlignment.ALIGN_NONE):
		self.record.size = 0 if self.isDirectory() else self.size
		self.record.offset = 0 if self.isDirectory() else len(data)
		records = [self.record]
		if self.isDirectory():
			for child in self.children:
				(sub_records, new_data) = child.generateRecords(data, alignment)
				records += sub_records
				data = new_data

			dotdot = self.record.copy()
			dotdot.name = '..'
			dotdot.opt = 0
			records.append(dotdot)
		else:
			alignment_extra = 0
			if alignment == CFGAlignment.ALIGN_START:
				alignment_extra = self.record.offset % 0x40
			elif self.record.size != 0 and alignment == CFGAlignment.ALIGN_END:
				alignment_extra = (self.record.offset + self.record.size) % 0x40
			if alignment_extra > 0:
					data += struct.pack("<B", 0) * (0x40 - alignment_extra)
					self.record.offset += 0x40 - alignment_extra
			data += self.data

		return (records, data)

	def __str__(self):
		return "%-32s [%4d bytes]" % (self.path, self.size)

	def __cmp__(self, other):
		if self.isDirectory() == other.isDirectory():
			return cmp(self.path, other.path)
		elif self.isDirectory():
			return -1
		else:
			return 1
