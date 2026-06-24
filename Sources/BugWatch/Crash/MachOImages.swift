import Foundation
import MachO

// MARK: - Async-signal-safe write primitives (no allocation, no String, no locks)
//
// These are `internal` (module-visible) so the crash handler in CrashReporter.swift
// can reuse `sigSafeWriteHex` for the `addrs:` section. Names are prefixed
// `sigSafe…` to avoid clashing with CrashReporter's file-private writers.

private let hexDigits: [UInt8] = [
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, // 0-9 a-f
]

/// Writes a `0x`-prefixed lowercase-hex unsigned integer using a fixed stack
/// buffer (a homogeneous tuple — never a heap array). Async-signal-safe.
@inline(__always)
func sigSafeWriteHex(_ fd: Int32, _ value: UInt) {
    var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    let cap = 18 // "0x" + up to 16 hex digits
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var n = value
        var i = cap
        hexDigits.withUnsafeBufferPointer { d in
            if n == 0 {
                i -= 1; p[i] = 0x30
            } else {
                while n > 0 { i -= 1; p[i] = d[Int(n & 0xF)]; n >>= 4 }
            }
        }
        i -= 1; p[i] = 0x78 // 'x'
        i -= 1; p[i] = 0x30 // '0'
        if let base = p.baseAddress { _ = write(fd, base + i, cap - i) }
    }
}

/// Writes `len` raw bytes as lowercase hex (no `0x`). Used for the 16-byte UUID.
/// Async-signal-safe.
@inline(__always)
func sigSafeWriteHexBytes(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ len: Int) {
    hexDigits.withUnsafeBufferPointer { d in
        var two: (UInt8, UInt8) = (0, 0)
        for k in 0..<len {
            let b = ptr[k]
            two.0 = d[Int(b >> 4)]
            two.1 = d[Int(b & 0xF)]
            withUnsafeBytes(of: &two) { _ = write(fd, $0.baseAddress!, 2) }
        }
    }
}

/// Writes a single space. Async-signal-safe.
@inline(__always)
func sigSafeWriteSpace(_ fd: Int32) {
    var c: UInt8 = 0x20
    _ = write(fd, &c, 1)
}

/// Writes a single '\n'. Async-signal-safe.
@inline(__always)
func sigSafeWriteNewline(_ fd: Int32) {
    var c: UInt8 = 0x0A
    _ = write(fd, &c, 1)
}

/// Writes a single byte. Async-signal-safe.
@inline(__always)
func sigSafeWriteByte(_ fd: Int32, _ byte: UInt8) {
    var c = byte
    _ = write(fd, &c, 1)
}

/// Writes a compile-time `StaticString` (its UTF-8 bytes). Async-signal-safe.
@inline(__always)
func sigSafeWriteStaticString(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { buf in
        if let base = buf.baseAddress, buf.count > 0 { _ = write(fd, base, buf.count) }
    }
}

/// Writes a NUL-terminated C string by pointer, walking to its NUL. Async-signal-safe.
@inline(__always)
func sigSafeWriteCStringPtr(_ fd: Int32, _ p: UnsafePointer<CChar>) {
    var len = 0
    while p[len] != 0 { len += 1 }
    if len > 0 { p.withMemoryRebound(to: UInt8.self, capacity: len) { _ = write(fd, $0, len) } }
}

// MARK: - Mach-O constants (local, typed — avoids import-typing mismatches)

private let MH_MAGIC_64_: UInt32 = 0xfeed_facf
private let MH_EXECUTE_: UInt32 = 0x2
private let LC_UUID_: UInt32 = 0x1b
private let LC_SEGMENT_64_: UInt32 = 0x19
private let CPU_TYPE_ARM64_: cpu_type_t = 0x0100_000c
private let CPU_TYPE_X86_64_: cpu_type_t = 0x0100_0007
private let CPU_SUBTYPE_ARM64E_: cpu_subtype_t = 2
private let CPU_SUBTYPE_MASK_: cpu_subtype_t = 0x00ff_ffff

/// `arm64`/`arm64e`/`x86_64`/`unknown` from a Mach-O cputype/cpusubtype.
func machoArchName(_ cputype: cpu_type_t, _ cpusubtype: cpu_subtype_t) -> StaticString {
    let sub = cpusubtype & CPU_SUBTYPE_MASK_
    if cputype == CPU_TYPE_ARM64_ { return sub == CPU_SUBTYPE_ARM64E_ ? "arm64e" : "arm64" }
    if cputype == CPU_TYPE_X86_64_ { return "x86_64" }
    return "unknown"
}

/// True when a 16-byte Mach-O `segname` equals exactly `__TEXT`.
private func segnameIsText(_ p: UnsafePointer<UInt8>) -> Bool {
    // "__TEXT" = 5f 5f 54 45 58 54, then a NUL.
    return p[0] == 0x5f && p[1] == 0x5f && p[2] == 0x54 &&
        p[3] == 0x45 && p[4] == 0x58 && p[5] == 0x54 && p[6] == 0x00
}

/// Walks the load commands of a 64-bit Mach-O header, returning the `__TEXT`
/// segment's virtual size and a pointer to the 16-byte `LC_UUID`. Pure pointer
/// arithmetic — async-signal-safe. Returns `(0, nil)` for non-64-bit headers.
func machoTextVMSizeAndUUID(_ header: UnsafePointer<mach_header>) -> (UInt64, UnsafePointer<UInt8>?) {
    guard header.pointee.magic == MH_MAGIC_64_ else { return (0, nil) }
    let raw = UnsafeRawPointer(header)
    let header64 = raw.assumingMemoryBound(to: mach_header_64.self)
    let ncmds = header64.pointee.ncmds
    var cmdPtr = raw.advanced(by: MemoryLayout<mach_header_64>.size)
    var vmsize: UInt64 = 0
    var uuidPtr: UnsafePointer<UInt8>? = nil
    var i: UInt32 = 0
    while i < ncmds {
        let lc = cmdPtr.assumingMemoryBound(to: load_command.self)
        let cmd = lc.pointee.cmd
        let cmdsize = Int(lc.pointee.cmdsize)
        if cmdsize <= 0 { break } // malformed — stop, never loop forever
        if cmd == LC_UUID_ {
            // uuid_command: cmd(4) + cmdsize(4) + uuid(16) → uuid at offset 8.
            uuidPtr = cmdPtr.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
        } else if cmd == LC_SEGMENT_64_ {
            // segment_command_64: …cmdsize(4..8), segname(8..24), vmaddr(24..32), vmsize(32..40)…
            let segname = cmdPtr.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
            if segnameIsText(segname) {
                vmsize = cmdPtr.advanced(by: 32).assumingMemoryBound(to: UInt64.self).pointee
            }
        }
        cmdPtr = cmdPtr.advanced(by: cmdsize)
        i += 1
    }
    return (vmsize, uuidPtr)
}

// MARK: - Crash-time image dump

/// Walks every loaded Mach-O image and writes one line per image:
/// `<loadAddrHex> <vmsizeHex> <uuid32hex> <arch> <0|1 main> <name>\n`.
/// Called from the signal handler under the `images:` marker. Async-signal-safe:
/// only `_dyld_*` reads, pointer arithmetic, and `write`.
func writeBinaryImages(_ fd: Int32) {
    let n = _dyld_image_count()
    var i: UInt32 = 0
    while i < n {
        guard let header = _dyld_get_image_header(i) else { i += 1; continue }
        let loadAddr = UInt(bitPattern: header)
        let (vmsize, uuidPtr) = machoTextVMSizeAndUUID(header)
        let isMain = (header.pointee.magic == MH_MAGIC_64_) &&
            (UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self).pointee.filetype == MH_EXECUTE_)
        sigSafeWriteHex(fd, loadAddr); sigSafeWriteSpace(fd)
        sigSafeWriteHex(fd, UInt(vmsize)); sigSafeWriteSpace(fd)
        if let u = uuidPtr { sigSafeWriteHexBytes(fd, u, 16) } else {
            for _ in 0..<16 { sigSafeWriteByte(fd, 0x30); sigSafeWriteByte(fd, 0x30) } // 32 '0'
        }
        sigSafeWriteSpace(fd)
        sigSafeWriteStaticString(fd, machoArchName(header.pointee.cputype, header.pointee.cpusubtype)); sigSafeWriteSpace(fd)
        sigSafeWriteByte(fd, isMain ? 0x31 : 0x30) // '1' / '0'
        sigSafeWriteSpace(fd)
        if let name = _dyld_get_image_name(i) { sigSafeWriteCStringPtr(fd, name) }
        sigSafeWriteNewline(fd)
        i += 1
    }
}

// MARK: - Test-only collector (NORMAL context — may use String/Foundation)

#if DEBUG
/// Collects the loaded images as structured `BinaryImage`s using the same walk,
/// for tests. NOT async-signal-safe (uses String) — never call from the handler.
func collectBinaryImagesForTest() -> [BinaryImage] {
    var out: [BinaryImage] = []
    let n = _dyld_image_count()
    var i: UInt32 = 0
    while i < n {
        defer { i += 1 }
        guard let header = _dyld_get_image_header(i) else { continue }
        let loadAddr = UInt(bitPattern: header)
        let (vmsize, uuidPtr) = machoTextVMSizeAndUUID(header)
        let isMain = (header.pointee.magic == MH_MAGIC_64_) &&
            (UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self).pointee.filetype == MH_EXECUTE_)
        let arch = "\(machoArchName(header.pointee.cputype, header.pointee.cpusubtype))"
        let name = _dyld_get_image_name(i).map { String(cString: $0) } ?? ""
        let debugId: String = uuidPtr.map { p in
            var bytes = [UInt8](repeating: 0, count: 16)
            for k in 0..<16 { bytes[k] = p[k] }
            return uuidString(from: bytes)
        } ?? "00000000-0000-0000-0000-000000000000"
        out.append(BinaryImage(
            name: name,
            debugId: debugId,
            arch: arch,
            imageAddr: "0x" + String(loadAddr, radix: 16),
            imageSize: vmsize,
            isMainImage: isMain
        ))
    }
    return out
}

/// Formats 16 raw bytes as a lowercase hyphenated UUID (8-4-4-4-12).
func uuidString(from bytes: [UInt8]) -> String {
    precondition(bytes.count == 16)
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let s = Array(hex)
    func slice(_ a: Int, _ b: Int) -> String { String(s[a..<b]) }
    return "\(slice(0,8))-\(slice(8,12))-\(slice(12,16))-\(slice(16,20))-\(slice(20,32))"
}
#endif
