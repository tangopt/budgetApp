import Foundation
import Compression

/// A minimal reader for ZIP archives held in memory — enough for OOXML files (.xlsx): stored
/// and deflated entries, no encryption, no ZIP64, no multi-disk. Inflation uses Apple's
/// Compression framework (raw DEFLATE, `COMPRESSION_ZLIB`), so it runs on macOS and iOS
/// without a third-party dependency. Entries are CRC-checked.
public struct ZipArchiveReader: Sendable {
    public enum ZipError: Error, Equatable {
        case notAZipArchive
        case corrupt(String)
        case unsupported(String)
        case entryNotFound(String)
        case tooLarge(String)
    }

    public struct Entry: Equatable, Sendable {
        public let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// The largest entry inflated (a guard against ZIP bombs).
    public static let maxEntrySize = 64 * 1024 * 1024

    private let bytes: [UInt8]
    public let entries: [Entry]

    public init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readCentralDirectory(bytes)
    }

    public func entry(_ path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// The uncompressed contents of the entry at `path`.
    public func contents(of path: String) throws -> Data {
        guard let entry = entry(path) else { throw ZipError.entryNotFound(path) }
        return try contents(of: entry)
    }

    public func contents(of entry: Entry) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw ZipError.unsupported("encrypted entry \(entry.path)") }
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.tooLarge(entry.path) }
        let local = entry.localHeaderOffset
        guard local + 30 <= bytes.count, Self.u32(bytes, local) == 0x0403_4b50 else { throw ZipError.corrupt("local header of \(entry.path)") }
        let start = local + 30 + Int(Self.u16(bytes, local + 26)) + Int(Self.u16(bytes, local + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.corrupt("data of \(entry.path)") }
        let compressed = bytes[start..<(start + entry.compressedSize)]
        let output: [UInt8]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupt("stored size of \(entry.path)") }
            output = Array(compressed)
        case 8:
            output = try Self.inflate(compressed, size: entry.uncompressedSize, path: entry.path)
        default:
            throw ZipError.unsupported("compression method \(entry.method) of \(entry.path)")
        }
        guard CRC32.checksum(output) == entry.crc32 else { throw ZipError.corrupt("checksum of \(entry.path)") }
        return Data(output)
    }

    private static func inflate(_ input: ArraySlice<UInt8>, size: Int, path: String) throws -> [UInt8] {
        guard size > 0 else { return [] }
        guard !input.isEmpty else { throw ZipError.corrupt("data of \(path)") }
        // One spare byte: a result that fills the buffer exactly is indistinguishable from a
        // truncated one, so a larger buffer tells the two apart.
        var output = [UInt8](repeating: 0, count: size + 1)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("inflated size of \(path)") }
        output.removeLast()
        return output
    }

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // The end-of-central-directory record is the last 22 bytes plus a comment of up to 64 KiB.
        guard bytes.count >= 22 else { throw ZipError.notAZipArchive }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var eocd: Int?
        var position = bytes.count - 22
        while position >= lowest {
            if u32(bytes, position) == 0x0605_4b50 { eocd = position; break }
            position -= 1
        }
        guard let eocd else { throw ZipError.notAZipArchive }
        let count = Int(u16(bytes, eocd + 10))
        let directoryOffset = Int(u32(bytes, eocd + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }
        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == 0x0201_4b50 else { throw ZipError.corrupt("central directory") }
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.corrupt("central directory") }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            let compressedSize = u32(bytes, cursor + 20)
            let uncompressedSize = u32(bytes, cursor + 24)
            let offset = u32(bytes, cursor + 42)
            guard compressedSize != 0xFFFF_FFFF, uncompressedSize != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else {
                throw ZipError.unsupported("ZIP64")
            }
            entries.append(Entry(path: name, method: u16(bytes, cursor + 10), flags: u16(bytes, cursor + 8), crc32: u32(bytes, cursor + 16),
                                 compressedSize: Int(compressedSize), uncompressedSize: Int(uncompressedSize), localHeaderOffset: Int(offset)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

/// CRC-32 (IEEE 802.3), as ZIP uses.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
