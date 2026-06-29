// offsetcheck.swift — validate the packed getattrlistbulk layout for the FULL set
// the real enumerator uses, now INCLUDING ATTR_CMN_CRTIME (Date Created).
// Build: swiftc -O offsetcheck.swift -o offsetcheck ; ./offsetcheck /usr/bin
import Darwin
import Foundation

let A_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
let A_CMN_NAME: UInt32    = 0x0000_0001
let A_CMN_FSID: UInt32    = 0x0000_0004
let A_CMN_OBJTYPE: UInt32 = 0x0000_0008
let A_CMN_CRTIME: UInt32  = 0x0000_0200
let A_CMN_MODTIME: UInt32 = 0x0000_0400
let A_CMN_FLAGS: UInt32   = 0x0004_0000
let A_CMN_FILEID: UInt32  = 0x0200_0000
let A_FILE_DATALENGTH: UInt32 = 0x0000_0200
let OPT_PACK_INVAL: UInt64 = 0x0000_0008
let OPT_NOFOLLOW: UInt64    = 0x0000_0001

// computed tight-packing offsets (ascending bit order):
// 0 len(4) | 4 returned(20) | 24 name(8) | 32 fsid(8) | 40 objtype(4)
// | 44 crtime(16) | 60 modtime(16) | 76 flags(4) | 80 fileid(8) | 88 datalen(8)
let OFF_NAMEREF = 24, OFF_OBJTYPE = 40
let OFF_CRSEC = 44, OFF_MODSEC = 60, OFF_FLAGS = 76, OFF_FILEID = 80, OFF_DATALEN = 88

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/usr/bin"
var attrList = attrlist()
attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
attrList.commonattr = A_CMN_RETURNED_ATTRS | A_CMN_NAME | A_CMN_FSID | A_CMN_OBJTYPE
    | A_CMN_CRTIME | A_CMN_MODTIME | A_CMN_FLAGS | A_CMN_FILEID
attrList.fileattr = A_FILE_DATALENGTH

let bufSize = 256 * 1024
let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
defer { buf.deallocate() }
let fd = open(dir, O_RDONLY, 0); precondition(fd >= 0); defer { close(fd) }

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
        let name = String(cString: (p + OFF_NAMEREF + nameOff).assumingMemoryBound(to: CChar.self))
        let crSec = p.loadUnaligned(fromByteOffset: OFF_CRSEC, as: Int64.self)
        let modSec = p.loadUnaligned(fromByteOffset: OFF_MODSEC, as: Int64.self)
        let dataLen = p.loadUnaligned(fromByteOffset: OFF_DATALEN, as: Int64.self)
        if printed < 8 {
            print("name=\(name) crtime=\(crSec) mtime=\(modSec) size=\(dataLen)")
            printed += 1
        }
        p = p + entryLen
    }
    if printed >= 8 { break outer }
}
