import XCTest
@testable import BugWatch
#if canImport(Darwin)
import Darwin
#endif

/// SP1 real-fixture verification: the Mach-O walker extracts genuine binary-image
/// metadata. We cross-check the parsed UUID against `dwarfdump --uuid` (the gold
/// standard) and the parsed load address against `dladdr` — proving the walker is
/// correct, not merely non-empty.
final class MachOImagesTests: XCTestCase {

    func testWalkerFindsImagesIncludingMainExecutable() {
        let images = collectBinaryImagesForTest()
        // A real process has many loaded dylibs.
        XCTAssertGreaterThan(images.count, 5, "expected many loaded images")
        let main = images.first { $0.isMainImage == true }
        XCTAssertNotNil(main, "no main executable image found")
        // Arch must be a real Apple slice.
        XCTAssertTrue(["arm64", "arm64e", "x86_64"].contains(main!.arch), "unexpected arch \(main!.arch)")
        // UUID must be a well-formed, non-zero, lowercase hyphenated UUID.
        let zero = "00000000-0000-0000-0000-000000000000"
        XCTAssertNotEqual(main!.debugId, zero, "main image UUID was all-zero (LC_UUID parse failed)")
        XCTAssertEqual(main!.debugId.count, 36)
        XCTAssertEqual(main!.debugId, main!.debugId.lowercased())
        XCTAssertEqual(main!.imageAddr.prefix(2), "0x")
    }

    /// Gold-standard: the parsed UUID must equal what `dwarfdump --uuid` reports
    /// for the same on-disk binary.
    func testParsedUUIDMatchesDwarfdump() throws {
        let images = collectBinaryImagesForTest()
        let main = try XCTUnwrap(images.first { $0.isMainImage == true })
        let path = main.name
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("main image path not on disk: \(path)")
        }
        guard let out = runDwarfdumpUUID(path) else {
            throw XCTSkip("dwarfdump unavailable")
        }
        // dwarfdump emits one "UUID: <UPPER> (<arch>) <path>" line per slice.
        let uuids = parseDwarfdumpUUIDs(out)
        XCTAssertFalse(uuids.isEmpty, "dwarfdump returned no UUIDs:\n\(out)")
        XCTAssertTrue(uuids.contains(main.debugId),
                      "parsed \(main.debugId) not in dwarfdump set \(uuids)")
    }

    /// The parsed load address of a system image must equal `dladdr`'s base for a
    /// symbol it contains — proving load-address extraction is correct. We use
    /// `dlsym` (returns a real code pointer, unlike a Swift function value).
    func testParsedLoadAddressMatchesDladdr() throws {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(RTLD_DEFAULT, "malloc") else {
            throw XCTSkip("dlsym(malloc) failed")
        }
        var info = Dl_info()
        guard dladdr(sym, &info) != 0, let base = info.dli_fbase else {
            throw XCTSkip("dladdr could not resolve malloc's image")
        }
        let baseHex = "0x" + String(UInt(bitPattern: base), radix: 16)
        let images = collectBinaryImagesForTest()
        XCTAssertTrue(images.contains { $0.imageAddr == baseHex },
                      "no collected image had malloc's image base \(baseHex)")
    }

    // MARK: helpers

    private func runDwarfdumpUUID(_ path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        proc.arguments = ["--uuid", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Pulls every UUID out of dwarfdump output, lowercased.
    private func parseDwarfdumpUUIDs(_ text: String) -> Set<String> {
        var set = Set<String>()
        for line in text.split(separator: "\n") {
            // "UUID: 79A20E2C-15B6-35F8-AF3C-44B135EA12D9 (arm64) /path"
            guard let r = line.range(of: "UUID: ") else { continue }
            let after = line[r.upperBound...]
            let uuid = after.prefix(36)
            if uuid.count == 36 { set.insert(uuid.lowercased()) }
        }
        return set
    }
}
