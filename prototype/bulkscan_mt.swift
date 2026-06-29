// bulkscan_mt.swift — multithreaded getattrlistbulk crawler prototype
// Uses a worker pool (default = core count) pulling directories from a shared
// stack. This is the real shape of Maverything's enumeration engine.
//
// Build:  swiftc -O bulkscan_mt.swift -o bulkscan_mt
// Run:    ./bulkscan_mt /            (or ~, or any path)  [workerCount]

import Darwin
import Foundation

let A_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
let A_CMN_NAME: UInt32           = 0x0000_0001
let A_CMN_OBJTYPE: UInt32        = 0x0000_0008
let A_CMN_MODTIME: UInt32        = 0x0000_0400
let A_CMN_FILEID: UInt32         = 0x0200_0000
let A_FILE_DATALENGTH: UInt32    = 0x0000_0200
let OPT_PACK_INVAL: UInt64       = 0x0000_0008
let OPT_NOFOLLOW: UInt64         = 0x0000_0001
let VDIR: UInt32 = 2

let OFF_NAMEREF = 24
let OFF_OBJTYPE = 32
let OFF_DATALEN = 60

final class Crawler {
    let cond = NSCondition()
    var stack: [String] = []
    var idle = 0
    var done = false
    let workers: Int

    // merged results
    var files = 0, dirs = 0, openErrors = 0
    var totalBytes: UInt64 = 0

    init(root: String, workers: Int) {
        self.workers = workers
        self.stack = [root]
    }

    func run() {
        let threads = (0..<workers).map { i -> Thread in
            let t = Thread { [weak self] in self?.worker() }
            t.stackSize = 4 << 20
            t.name = "crawl-\(i)"
            return t
        }
        threads.forEach { $0.start() }
        // wait for completion
        cond.lock()
        while !(done && stack.isEmpty) { cond.wait() }
        cond.unlock()
        // workers exit on their own once done is set; give them a moment
        var allDone = false
        while !allDone { allDone = threads.allSatisfy { $0.isFinished } }
    }

    private func worker() {
        var lFiles = 0, lDirs = 0, lErr = 0
        var lBytes: UInt64 = 0
        let bufSize = 512 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = A_CMN_RETURNED_ATTRS | A_CMN_NAME | A_CMN_OBJTYPE | A_CMN_MODTIME | A_CMN_FILEID
        attrList.fileattr = A_FILE_DATALENGTH
        let options = OPT_PACK_INVAL | OPT_NOFOLLOW

        var children: [String] = []

        cond.lock()
        while true {
            if let dir = stack.popLast() {
                cond.unlock()
                children.removeAll(keepingCapacity: true)
                scanDir(dir, buf: buf, bufSize: bufSize, attrList: &attrList, options: options,
                        files: &lFiles, dirs: &lDirs, bytes: &lBytes, err: &lErr, children: &children)
                cond.lock()
                if !children.isEmpty { stack.append(contentsOf: children); cond.broadcast() }
                continue
            }
            idle += 1
            if idle == workers { done = true; cond.broadcast() }
            while stack.isEmpty && !done { cond.wait() }
            idle -= 1
            if done && stack.isEmpty { break }
        }
        // merge
        files += lFiles; dirs += lDirs; openErrors += lErr; totalBytes &+= lBytes
        cond.unlock()
    }

    private func scanDir(_ dir: String, buf: UnsafeMutableRawPointer, bufSize: Int,
                         attrList: inout attrlist, options: UInt64,
                         files: inout Int, dirs: inout Int, bytes: inout UInt64,
                         err: inout Int, children: inout [String]) {
        let fd = open(dir, O_RDONLY, 0)
        if fd < 0 { err += 1; return }
        defer { close(fd) }
        let isRoot = (dir == "/")
        while true {
            let count = withUnsafeMutablePointer(to: &attrList) { alp in
                getattrlistbulk(fd, alp, buf, bufSize, options)
            }
            if count <= 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let entryLen = Int(p.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                let objType  = p.loadUnaligned(fromByteOffset: OFF_OBJTYPE, as: UInt32.self)
                if objType == VDIR {
                    dirs += 1
                    let nameOff = Int(p.loadUnaligned(fromByteOffset: OFF_NAMEREF, as: Int32.self))
                    let namePtr = (p + OFF_NAMEREF + nameOff).assumingMemoryBound(to: CChar.self)
                    let name = String(cString: namePtr)
                    if name != "." && name != ".." {
                        children.append(isRoot ? "/" + name : dir + "/" + name)
                    }
                } else {
                    let dl = p.loadUnaligned(fromByteOffset: OFF_DATALEN, as: Int64.self)
                    if dl > 0 { bytes &+= UInt64(dl) }
                    files += 1
                }
                p = p + entryLen
            }
        }
    }
}

let args = CommandLine.arguments
let root = args.count > 1 ? args[1] : FileManager.default.homeDirectoryForCurrentUser.path
let workers = args.count > 2 ? (Int(args[2]) ?? 10) : ProcessInfo.processInfo.activeProcessorCount

let clock = ContinuousClock()
let start = clock.now
let c = Crawler(root: root, workers: workers)
c.run()
let elapsed = start.duration(to: clock.now)
let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
let total = c.files + c.dirs
let perSec = secs > 0 ? Double(total) / secs : 0

print("root            : \(root)")
print("workers         : \(workers)")
print("files           : \(c.files)")
print("dirs            : \(c.dirs)")
print("total entries   : \(total)")
print("total size      : \(String(format: "%.2f", Double(c.totalBytes) / 1e9)) GB")
print("open errors     : \(c.openErrors)  (permission-denied dirs)")
print(String(format: "elapsed         : %.3f s", secs))
print(String(format: "throughput      : %.0f entries/sec", perSec))
