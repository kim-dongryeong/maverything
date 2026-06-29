// offsetcheck.swift — validate the packed getattrlistbulk record layout for the
// full attribute set we'll use in the real enumerator. Prints name/size/mtime so
// we can diff against `stat`.  Build: swiftc -O offsetcheck.swift -o offsetcheck
import Darwin
import Foundation

let A_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
let A_CMN_NAME: UInt32    = 0x0000_0001
let A_CMN_FSID: UInt32    = 0x0000_0004
let A_CMN_OBJTYPE: UInt32 = 0x0000_0008
let A_CMN_MODTIME: UInt32 = 0x0000_0400
let A_CMN_FLAGS: UInt32   = 0x0004_0000
let A_CMN_FILEID: UInt32  = 0x0200_0000
let A_FILE_DATALENGTH: UInt32 = 0x0000_0200
let OPT_PACK_INVAL: UInt64 = 0x0000_0008
let OPT_NOFOLLOW: UInt64    = 0x0000_0001

// computed tight-packing offsets
let OFF_NAMEREF = 24
let OFF_FSID    = 32
let OFF_OBJTYPE = 40
let OFF_MODSEC  = 44
let OFF_MODNSEC = 52
let OFF_FLAGS   = 60
let OFF_FILEID  = 64
let OFF_DATALEN = 72

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/usr/bin"
var attrList = attrlist()
attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
attrList.commonattr = A_CMN_RETURNED_ATTRS | A_CMN_NAME | A_CMN_FSID | A_CMN_OBJTYPE | A_CMN_MODTIME | A_CMN_FLAGS | A_CMN_FILEID
attrList.fileattr = A_FILE_DATALENGTH

let bufSize = 256 * 1024
let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
defer { buf.deallocate() }
let fd = open(dir, O_RDONLY, 0)
precondition(fd >= 0, "open failed")
defer { close(fd) }

var printed = 0
outer: while true {
    let count = withUnsafeMutablePointer(to: &attrList) { alp in
        getattrlistbulk(fd, alp, buf, bufSize, OPT_PACK_INVAL | OPT_NOFOLLOW)
    }
    if count <= 0 { break }
    var p = UnsafeRawPointer(buf)
    for _ in 0..<count {
        let entryLen = Int(p.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        let nameOff = Int(p.loadUnaligned(fromByteOffset: OFF_NAMEREF, as: Int32.self))
        let namePtr = (p + OFF_NAMEREF + nameOff).assumingMemoryBound(to: CChar.self)
        let name = String(cString: namePtr)
        let objType = p.loadUnaligned(fromByteOffset: OFF_OBJTYPE, as: UInt32.self)
        let modSec = p.loadUnaligned(fromByteOffset: OFF_MODSEC, as: Int64.self)
        let flags = p.loadUnaligned(fromByteOffset: OFF_FLAGS, as: UInt32.self)
        let fileID = p.loadUnaligned(fromByteOffset: OFF_FILEID, as: UInt64.self)
        let dataLen = p.loadUnaligned(fromByteOffset: OFF_DATALEN, as: Int64.self)
        if printed < 12 {
            print("name=\(name) type=\(objType) size=\(dataLen) mtime=\(modSec) inode=\(fileID) flags=\(flags) entryLen=\(entryLen)")
            printed += 1
        }
        p = p + entryLen
    }
    if printed >= 12 { break outer }
}
