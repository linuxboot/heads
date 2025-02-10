# SPDX-License-Identifier: GPL-2.0-only
# This code is based on MFSUtil by Youness Alaoui (see `doc/LICENSE.orig` for original copyright)

import struct
from functools import cmp_to_key

INTEL_IDX   = 6     # Default configuration
FITC_IDX    = 7     # Vendor configuration
HOME_IDX    = 8     # Runtime ME data

def cmp(a, b):
        return (a > b) - (a < b)

class MFS(object):
    PAGE_SIZE = 0x2000 # Page size is 8K
    CHUNK_SIZE = 0x40 # Chunk size is 64 bytes
    CHUNK_CRC_SIZE = 2 # Size of CRC16
    CHUNKS_PER_DATA_PAGE = 122 # 122 chunks per Data page
    CHUNKS_PER_SYSTEM_PAGE = 120 # 120 chunks per System page

    CRC8TabLo = bytearray([0, 7, 14, 9, 28, 27, 18, 21, 56, 63, 54, 49, 36, 35, 42, 45])
    CRC8TabHi = bytearray([0, 112, 224, 144, 199, 183, 39, 87, 137, 249, 105, 25, 78, 62, 174, 222])
    CRC16Tab = [0]*256
    for i in range(256):
        r = i << 8
        for j in range(8): r = (r << 1) ^ (0x1021 if r & 0x8000 else 0)
        CRC16Tab[i] = r & 0xFFFF

    def __init__(self, data):
        self.data = data
        self.size = len(self.data)
        assert self.size % self.PAGE_SIZE == 0

        self.num_pages = self.size // self.PAGE_SIZE # Total number of pages
        self.num_sys_pages = self.num_pages // 12 # Number of System pages
        self.num_data_pages = self.num_pages - self.num_sys_pages - 1 # Number of Data pages
        self.capacity = self.num_data_pages * self.CHUNKS_PER_DATA_PAGE * self.CHUNK_SIZE

        self.data_pages = []
        self.sys_pages = []
        self.to_be_erased = None
        for page in range(self.num_pages):
            page = MFSPage(self.data[page * self.PAGE_SIZE:(page + 1) * self.PAGE_SIZE], page) # Load page
            if page.isToBeErased():
                assert self.to_be_erased == None
                self.to_be_erased = page
            elif page.isSystemPage():
                self.sys_pages.append(page)
            else:
                self.data_pages.append(page)

        assert self.num_sys_pages == len(self.sys_pages)
        assert self.num_data_pages == len(self.data_pages)

        self.sys_pages.sort(key=cmp_to_key(MFSPage.__cmp__))
        self.data_pages.sort(key=cmp_to_key(MFSPage.__cmp__))

        self.system_volume = MFSSystemVolume(self.sys_pages, self.data_pages)


    def getSystemVolume(self):
        return self.system_volume

    def generate(self):
        for sys_page in self.sys_pages:
            sys_page.resetChunks()
        for data_page in self.data_pages:
            data_page.resetChunks()

        self.system_volume.generate()
        system_chunks = self.system_volume.generateChunks()
        for i in range(0, len(self.sys_pages)):
            chunks = system_chunks[i * MFS.CHUNKS_PER_SYSTEM_PAGE: (i+1) * MFS.CHUNKS_PER_SYSTEM_PAGE]
            self.sys_pages[i].setChunks(chunks)
            self.sys_pages[i].generate()

        for file in self.system_volume.iterateFiles():
            chunks = file.generateChunks()
            for chunk in chunks:
                data_page_idx = (chunk.id - self.system_volume.total_chunks) // MFS.CHUNKS_PER_DATA_PAGE
                self.data_pages[data_page_idx].addChunk(chunk)
        for data_page in self.data_pages:
            data_page.generate()
        self.data = b""
        for sys_page in self.sys_pages:
            self.data += sys_page.data
        for data_page in self.data_pages:
            self.data += data_page.data
        self.data += self.to_be_erased.data

    def __str__(self):
        res = f"Pages : {self.num_pages} ({self.num_sys_pages} System && {self.num_data_pages} Data)\nSystem Pages:\n"
        for i in range(self.num_sys_pages):
            res += f"  {i}: {self.sys_pages[i]}\n"
        res += "Data Pages:\n"
        for i in range(self.num_data_pages):
            res += f"  {i}: {self.data_pages[i]}\n"
        res += f"\nSystem Volume : \n{self.system_volume}"
        return res

    @staticmethod
    def CrcIdx(w, crc=0x3FFF):
        for b in bytearray(struct.pack("<H", w)):
            crc = (MFS.CRC16Tab[b ^ (crc >> 8)] ^ (crc << 8)) & 0x3FFF
        return crc

    @staticmethod
    def Crc16(ab, crc=0xFFFF):
        for b in bytearray(ab):
            crc = (MFS.CRC16Tab[b ^ (crc >> 8)] ^ (crc << 8)) & 0xFFFF
        return crc

    @staticmethod
    def Crc8(ab):
        csum = 1
        for b in bytearray(ab):
            b ^= csum
            csum = MFS.CRC8TabLo[b & 0xF] ^ MFS.CRC8TabHi[b >> 4]
        return csum

class MFSPage(object):
    PAGE_HEADER_FMT = struct.Struct("<LLLHHBB")
    SYSTEM_PAGE_INDICES_FMT = struct.Struct("<%dHH" % MFS.CHUNKS_PER_SYSTEM_PAGE)
    DATA_PAGE_INDICES_FMT = struct.Struct("<%dB" % MFS.CHUNKS_PER_DATA_PAGE)
    MFS_PAGE_SIGNATURE = 0xAA557887

    def __init__(self, data, page_id):
        self.data = data
        self.page_id = page_id
        (self.signature, self.USN, self.num_erase, self.next_erase,
         self.first_chunk, self.crc, zero) = self.PAGE_HEADER_FMT.unpack_from(self.data)

        crc = MFS.Crc8(self.data[:self.PAGE_HEADER_FMT.size - 2])
        assert zero == 0
        assert self.signature == 0 or \
            (self.signature == self.MFS_PAGE_SIGNATURE and self.crc == crc)

        if self.isToBeErased():
            return

        self.chunks = []
        if self.isSystemPage():
            chunk_ids = self.SYSTEM_PAGE_INDICES_FMT.unpack_from(self.data, self.PAGE_HEADER_FMT.size)
            last_chunk_id = 0
            for chunk in range(MFS.CHUNKS_PER_SYSTEM_PAGE):
                # End of chunks
                if chunk_ids[chunk] == 0x7FFF or chunk_ids[chunk] == 0xFFFF:
                    break

                last_chunk_id = MFS.CrcIdx(last_chunk_id) ^ chunk_ids[chunk]
                offset = self.PAGE_HEADER_FMT.size + self.SYSTEM_PAGE_INDICES_FMT.size + \
                                 chunk * (MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE)
                data = self.data[offset:offset + MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE]
                self.chunks.append(MFSChunk(data, last_chunk_id))
        else:
            data_free = self.DATA_PAGE_INDICES_FMT.unpack_from(self.data, self.PAGE_HEADER_FMT.size)
            self.chunks = [None] * MFS.CHUNKS_PER_DATA_PAGE
            for chunk in range(MFS.CHUNKS_PER_DATA_PAGE):
                if data_free[chunk] == 0:
                    offset = self.PAGE_HEADER_FMT.size + self.DATA_PAGE_INDICES_FMT.size + \
                                     chunk * (MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE)
                    data = self.data[offset:offset+MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE]
                    chunk_id = self.first_chunk + chunk
                    self.chunks[chunk] = MFSChunk(data, chunk_id)

    def isToBeErased(self):
        return self.signature == 0

    def isSystemPage(self):
        return not self.isToBeErased() and self.first_chunk == 0

    def isDataPage(self):
        return not self.isToBeErased() and not self.isSystemPage()

    def getChunk(self, id):
        if self.isDataPage() and \
             id >= self.first_chunk and \
             id < self.first_chunk + MFS.CHUNKS_PER_DATA_PAGE:
            return self.chunks[id - self.first_chunk]
        return None

    def resetChunks(self):
        if self.isSystemPage():
            self.chunks = []
        else:
            self.chunks = [None] * MFS.CHUNKS_PER_DATA_PAGE

    def setChunks(self, chunks):
        self.chunks = chunks

    def addChunk(self, chunk):
        id = chunk.id
        assert self.isDataPage() and \
            id >= self.first_chunk and \
            id < self.first_chunk + MFS.CHUNKS_PER_DATA_PAGE
        self.chunks[id - self.first_chunk] = chunk

    def generate(self):
        data = self.PAGE_HEADER_FMT.pack(self.signature, self.USN, self.num_erase, self.next_erase,
                                                                         self.first_chunk, 0, 0)
        crc = MFS.Crc8(data[:-2])
        data = self.PAGE_HEADER_FMT.pack(self.signature, self.USN, self.num_erase, self.next_erase,
                                                                         self.first_chunk, crc, 0)
        if self.isSystemPage():
            assert len(self.chunks) <= MFS.CHUNKS_PER_SYSTEM_PAGE
            chunk_ids = []
            last_chunk_id = 0
            for i, chunk in enumerate(self.chunks):
                chunk_ids.append(MFS.CrcIdx(last_chunk_id) ^ chunk.id)
                last_chunk_id = chunk.id
            if len(self.chunks) == MFS.CHUNKS_PER_SYSTEM_PAGE or len(self.chunks) == 0:
                chunk_ids.append(0xFFFF)
            else:
                # Use case of exactly 120 chunks in the last system page...
                chunk_ids.append(0x7FFF)
            chunk_ids += [0xFFFF] * (MFS.CHUNKS_PER_SYSTEM_PAGE - len(self.chunks))
            assert len(chunk_ids) == MFS.CHUNKS_PER_SYSTEM_PAGE + 1
            data += self.SYSTEM_PAGE_INDICES_FMT.pack(*chunk_ids)
            for chunk in self.chunks:
                data += chunk.getRawData()
            data += b'\xFF' * ((MFS.CHUNKS_PER_SYSTEM_PAGE - len(self.chunks)) * \
                                                (MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE) + 0xC)
        else:
            assert len(self.chunks) == MFS.CHUNKS_PER_DATA_PAGE
            data_free = []
            for i, chunk in enumerate(self.chunks):
                if chunk:
                    assert chunk.id == self.first_chunk + i
                    data_free.append(0)
                else:
                    data_free.append(0xFF)
            data += self.DATA_PAGE_INDICES_FMT.pack(*data_free)
            for i, chunk in enumerate(self.chunks):
                if chunk:
                    data += chunk.getRawData()
                else:
                    data += b"\xFF" * (MFS.CHUNK_SIZE + MFS.CHUNK_CRC_SIZE)
        assert len(data) == MFS.PAGE_SIZE
        self.data = data

    def __cmp__(self, other):
        assert self.signature == other.signature and not self.isToBeErased()
        assert self.isSystemPage() == other.isSystemPage()
        if self.isSystemPage():
            return cmp(self.USN, other.USN)
        else:
            return cmp(self.first_chunk, other.first_chunk)

    def __str__(self):
        if self.isToBeErased():
            return "ToBeErased"
        if self.isSystemPage():
            chunk_ids = set()
            for i in range(len(self.chunks)):
                chunk_ids.add(str(self.chunks[i].id))
            chunk_ids = list(chunk_ids)
            chunk_ids.sort()
            res = "System-%d (USN: 0x%X): %s" % (self.page_id, self.USN, ", ".join(chunk_ids))
        else:
            res = "Data-%d: %X" % (self.page_id, self.first_chunk)
        return res

    def __repr__(self):
        return str(self)

class MFSChunk(object):
    def __init__(self, data, chunk_id, raw=True):
        self.chunk_id = chunk_id
        if raw:
            assert len(data) == MFS.CHUNK_SIZE + 2
            self.data = data[:-2]
            self.crc, = struct.unpack("<H", data[-2:])
            assert self.crc == MFS.Crc16(self.data + struct.pack("<H", self.chunk_id))
        else:
            assert len(data) == MFS.CHUNK_SIZE
            self.data = data
            self.checkSum()

    def checkSum(self):
        self.crc = MFS.Crc16(self.data + struct.pack("<H", self.chunk_id))
        return self.crc

    def getRawData(self):
        self.checkSum()
        return self.data + struct.pack("<H", self.crc)

    @property
    def id(self):
        return self.chunk_id

class MFSSystemVolume(object):
    SYSTEM_VOLUME_HEADER_FMT = struct.Struct("<LLLH")
    SYSTEM_VOLUME_SIGNATURE = 0x724F6201

    def __init__(self, system_pages, data_pages):
        self.total_chunks = data_pages[0].first_chunk
        self.data = b"\x00" * (self.total_chunks * MFS.CHUNK_SIZE)

        for page in system_pages:
            for chunk in page.chunks:
                self.data = self.data[0:chunk.id * MFS.CHUNK_SIZE] + \
                                        chunk.data + \
                                        self.data[(chunk.id + 1) * MFS.CHUNK_SIZE:]

        (self.signature, self.version, self.capacity, self.num_files) \
            = self.SYSTEM_VOLUME_HEADER_FMT.unpack_from(self.data)

        assert self.signature == self.SYSTEM_VOLUME_SIGNATURE
        assert self.version == 1
        self.files = [None] * self.num_files
        self.file_ids = list(struct.unpack_from("<%dH" % self.num_files,
            self.data, self.SYSTEM_VOLUME_HEADER_FMT.size))
        self.data_ids = list(struct.unpack_from("<%dH" % (len (data_pages) * MFS.CHUNKS_PER_DATA_PAGE),
            self.data, self.SYSTEM_VOLUME_HEADER_FMT.size + self.num_files * 2))
        for id, chain in enumerate(self.file_ids):
            if chain == 0xFFFF:
                # Empty file
                self.files[id] = MFSFile(id)
            elif chain != 0 and chain != 0xFFFE:
                self.files[id] = MFSFile(id)
                while chain > 0:
                    data_chunk_idx = chain - self.num_files
                    page_idx = data_chunk_idx // MFS.CHUNKS_PER_DATA_PAGE
                    chunk = data_pages[page_idx].getChunk(self.total_chunks + data_chunk_idx)
                    next_chain = self.data_ids[data_chunk_idx]
                    size = MFS.CHUNK_SIZE if next_chain > MFS.CHUNK_SIZE else next_chain
                    self.files[id].addChunk(chunk, size)
                    if next_chain <= MFS.CHUNK_SIZE:
                        break
                    chain = next_chain

    @property
    def numFiles(self):
        return self.num_files

    def getFile(self, id):
        if id >= 0 and id <= self.num_files:
            return self.files[id]
        return None

    def iterateFiles(self):
        for id in range(self.num_files):
            if self.files[id]:
                yield self.files[id]

    def removeFile(self, id):
        if id < 0 or id > self.num_files:
            return
        file = self.files[id]
        if file is None:
            return
        self.files[id] = None
        chain = self.file_ids[id]
        self.file_ids[id] = 0
        while chain > MFS.CHUNK_SIZE:
            next_chain = self.data_ids[chain - self.num_files]
            self.data_ids[chain - self.num_files] = 0
            chain = next_chain

    def addFile(self, id, data, optimize=True):
        self.removeFile(id)
        file = MFSFile(id)
        size = len(data)
        data_chain = []
        for offset in range(0, size, MFS.CHUNK_SIZE):
            if optimize:
                chain = self.getNextFreeDataChunk()
            else:
                chain = self.getLastFreeDataChunk()
            if chain == -1:
                # If not enough space, free previously set chains
                for chain in data_chain:
                    self.data_ids[chain] = 0
                return False
            file.addData(self.total_chunks + chain, data[offset:offset+MFS.CHUNK_SIZE])
            if len(data_chain) > 0:
                self.data_ids[data_chain[-1]] = chain + self.num_files
            data_chain.append(chain)
            self.data_ids[chain] = size - offset
        if len(data_chain) > 0:
            self.file_ids[id] = data_chain[0] + self.num_files
        else:
            # Empty file
            self.file_ids[id] = 0xFFFF
        self.files[id] = file

    def getNextFreeDataChunk(self):
        for i, chain in enumerate(self.data_ids):
            if chain == 0:
                return i
        return -1

    def getLastFreeDataChunk(self):
        for i, chain in reversed(list(enumerate(self.data_ids))):
            if chain == 0:
                return i
        return -1

    def generate(self):
        data = self.SYSTEM_VOLUME_HEADER_FMT.pack(self.signature, self.version, self.capacity, self.num_files) + \
                                struct.pack("<%dH" % self.num_files, *self.file_ids) + \
                                struct.pack("<%dH" % len (self.data_ids), *self.data_ids)
        total_data_size = (len(data) + MFS.CHUNK_SIZE - 1) & ~(MFS.CHUNK_SIZE - 1)
        self.data = data.ljust(total_data_size, b'\0')

    def generateChunks(self):
        self.generate()
        empty_data = b'\0' * MFS.CHUNK_SIZE
        chunks = []
        for offset in range(0, len(self.data), MFS.CHUNK_SIZE):
            data = self.data[offset:offset + MFS.CHUNK_SIZE]
            if data == empty_data:
                continue
            chunk = MFSChunk(data, offset // MFS.CHUNK_SIZE, False)
            chunks.append(chunk)
        return chunks

    def _listDirRecursive(self, file, integrity, prefix):
        for dirent in file.decodeDir(integrity):
            # Skip relative references
            if dirent.name == "." or dirent.name == "..":
                continue
            # Absolute path to this file
            path = prefix + "/" + dirent.name
            file = self.getFile(dirent.id())
            # Yield field itself
            yield path, file.decodeData(dirent.integrity())
            # Recursively yield entries if it is a subdirectory
            if dirent.directory():
                yield from self._listDirRecursive(file, dirent.integrity(), prefix=path)

    def listDir(self, id, integrity, prefix):
        file = self.getFile(id)
        # Yield the root itself
        yield prefix, file.decodeData(integrity)
        # List its subdirectories
        yield from self._listDirRecursive(file, integrity, prefix)

    def __str__(self):
        res = f"Total of {self.num_files} file entries\n"
        for i, f in enumerate(self.files):
            if f:
                res += f"{i}: {f}\n"
        return res

DIRECTORY_ENTRY_SIZE    = 24
INTEGRITY_BLOB_SIZE     = 52

class MFSFile(object):
    def __init__(self, id):
        self.id = id
        self.chain = []
        self.data = b""

    def addChunk(self, chunk, size):
        self.chain.append(chunk.id)
        self.data = self.data + chunk.data[:size]

    def addData(self, id, data):
        self.chain.append(id)
        self.data = self.data + data

    def generateChunks(self):
        chunks = []
        for i, chain in enumerate(self.chain):
            data = self.data[i * MFS.CHUNK_SIZE:(i + 1) * MFS.CHUNK_SIZE]
            data = data.ljust(MFS.CHUNK_SIZE, b'\0')
            chunk = MFSChunk(data, chain, False)
            chunks.append(chunk)
        return chunks

    def decodeData(self, integrity):
        if integrity:
            return self.data[:-INTEGRITY_BLOB_SIZE]
        return self.data

    def decodeDir(self, integrity):
        data = self.decodeData(integrity)
        # Decode directory entries
        for i in range(0, len(data), DIRECTORY_ENTRY_SIZE):
            yield MFSDirectoryEntry(data[i:i + DIRECTORY_ENTRY_SIZE])

    def __str__(self):
        return f"File {self.id} has {len(self.data)} bytes (Chain: {self.chain})"

class MFSDirectoryEntry:
    FILE   = 0
    DIR    = 1

    def __init__(self, data):
        self.fileno, self.mode, self.uid, self.gid, self.salt, self.name = \
            struct.unpack("<IHHHH12s", data)
        self.name = cstr(self.name).decode()

    def id(self):
        return self.fileno & 0xfff

    def integrity(self):
        return (self.mode & 1<<9) != 0

    def directory(self):
        return (self.mode & 1<<14) != 0

def cstr(s):
    nulidx = s.find(b"\0")
    if nulidx != -1:
        return s[:nulidx]
    return s
