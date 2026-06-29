// bulkscan.swift — Maverything enumeration speed prototype
// Recursively enumerates a directory tree using getattrlistbulk() and measures
// throughput. This validates the macOS analog of Everything's "read the MFT" trick.
//
// Build:  swiftc -O bulkscan.swift -o bulkscan
// Run:    ./bulkscan /            (or ~, or any path)

import Darwin
import Foundation

// MARK: - attr bits (sys/attr.h), declared as UInt32 to avoid import-type friction

let A_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
let A_CMN_NAME: UInt32           = 0x0000_0001
let A_CMN_OBJTYPE: UInt32        = 0x0000_0008
let A_CMN_MODTIME: UInt32        = 0x0000_0400
let A_CMN_FILEID: UInt32         = 0x0200_0000
let A_FILE_DATALENGTH: UInt32    = 0x0000_0200

let OPT_PACK_INVAL: UInt64       = 0x0000_0008   // FSOPT_PACK_INVAL_ATTRS
let OPT_NOFOLLOW: UInt64         = 0x0000_0001   // FSOPT_NOFOLLOW

let VREG: UInt32 = 1
let VDIR: UInt32 = 2

// MARK: - packed-record field offsets (tight packing, no alignment padding)
// 0  : u32  entry length
// 4  : attribute_set_t returned (5 x u32 = 20)
// 24 : attrreference_t name (i32 dataoffset, u32 length)
// 32 : u32  objtype
// 36 : timespec modtime (16)
// 52 : u64  fileid
// 60 : i64  datalength
// 68 : name bytes ...
let OFF_NAMEREF = 24
let OFF_OBJTYPE = 32
let OFF_MODTIME = 36
let OFF_FILEID  = 52
let OFF_DATALEN = 60

struct Stats {
    var files = 0
    var dirs = 0
    var totalBytes: UInt64 = 0
    var openErrors = 0
}

func scan(root: String) -> Stats {
    var stats = Stats()
    var stack: [String] = [root]

    var attrList = attrlist()
    attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT) // 5
    attrList.commonattr = A_CMN_RETURNED_ATTRS | A_CMN_NAME | A_CMN_OBJTYPE | A_CMN_MODTIME | A_CMN_FILEID
    attrList.fileattr = A_FILE_DATALENGTH

    let bufSize = 256 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
    defer { buf.deallocate() }

    let options = OPT_PACK_INVAL | OPT_NOFOLLOW

    while let dir = stack.popLast() {
        let fd = open(dir, O_RDONLY, 0)
        if fd < 0 { stats.openErrors += 1; continue }
        defer { close(fd) }

        while true {
            let count = withUnsafeMutablePointer(to: &attrList) { alp in
                getattrlistbulk(fd, alp, buf, bufSize, options)
            }
            if count <= 0 { break } // 0 == done, <0 == error

            var p = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let entryLen = Int(p.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                let objType  = p.loadUnaligned(fromByteOffset: OFF_OBJTYPE, as: UInt32.self)

                if objType == VDIR {
                    stats.dirs += 1
                    // build child path and queue it
                    let nameOff = Int(p.loadUnaligned(fromByteOffset: OFF_NAMEREF, as: Int32.self))
                    let namePtr = (p + OFF_NAMEREF + nameOff).assumingMemoryBound(to: CChar.self)
                    let name = String(cString: namePtr)
                    if name != "." && name != ".." {
                        stack.append(dir == "/" ? "/" + name : dir + "/" + name)
                    }
                } else {
                    if objType == VREG {
                        let dl = p.loadUnaligned(fromByteOffset: OFF_DATALEN, as: Int64.self)
                        if dl > 0 { stats.totalBytes &+= UInt64(dl) }
                    }
                    stats.files += 1
                }
                p = p + entryLen
            }
        }
    }
    return stats
}

// MARK: - main

let args = CommandLine.arguments
let root = args.count > 1 ? args[1] : FileManager.default.homeDirectoryForCurrentUser.path

let clock = ContinuousClock()
let start = clock.now
let stats = scan(root: root)
let elapsed = start.duration(to: clock.now)
let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

let total = stats.files + stats.dirs
let perSec = secs > 0 ? Double(total) / secs : 0

print("root            : \(root)")
print("files           : \(stats.files)")
print("dirs            : \(stats.dirs)")
print("total entries   : \(total)")
print("total size      : \(String(format: "%.2f", Double(stats.totalBytes) / 1e9)) GB")
print("open errors     : \(stats.openErrors)")
print(String(format: "elapsed         : %.3f s", secs))
print(String(format: "throughput      : %.0f entries/sec", perSec))
