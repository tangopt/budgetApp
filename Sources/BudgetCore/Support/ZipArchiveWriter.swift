import Foundation
import Compression

/// A minimal ZIP writer for OOXML files, the counterpart of `ZipArchiveReader`: entries are
/// deflated (raw DEFLATE through Apple's Compression framework, macOS and iOS) when that makes
/// them smaller, else stored. No ZIP64, no encryption; timestamps are fixed (1 Jan 1980) so the
/// same input always gives the same bytes.
public struct ZipArchiveWriter {
    public enum ZipWriteError: Error, Equatable {
        case tooLarge(String)
        case tooManyEntries
    }

    private var entries: [(path: String, data: [UInt8])] = []

    public init() {}

    /// Adds a file; paths use "/" and no leading slash.
    public mutating func add(_ path: String, data: Data) {
        entries.append((path, [UInt8](data)))
    }

    public mutating func add(_ path: String, text: String) {
        add(path, data: Data(text.utf8))
    }

    /// The archive's bytes.
    public func archive() throws -> Data {
        guard entries.count < 0xFFFF else { throw ZipWriteError.tooManyEntries }
        var output: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            guard entry.data.count < 0xFFFF_FFFF, output.count < 0xFFFF_FFFF else { throw ZipWriteError.tooLarge(entry.path) }
            let name = [UInt8](entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let deflated = Self.deflate(entry.data)
            let (method, payload): (UInt16, [UInt8]) = deflated.map { $0.count < entry.data.count ? (8, $0) : (0, entry.data) } ?? (0, entry.data)
            let offset = UInt32(output.count)
            // Local file header.
            output += Self.u32(0x0403_4b50) + Self.u16(20) + Self.u16(0x0800) + Self.u16(method) + Self.u16(0) + Self.u16(0x0021)
                + Self.u32(crc) + Self.u32(UInt32(payload.count)) + Self.u32(UInt32(entry.data.count))
                + Self.u16(UInt16(name.count)) + Self.u16(0) + name
            output += payload
            // Central directory record.
            central += Self.u32(0x0201_4b50) + Self.u16(20) + Self.u16(20) + Self.u16(0x0800) + Self.u16(method) + Self.u16(0) + Self.u16(0x0021)
                + Self.u32(crc) + Self.u32(UInt32(payload.count)) + Self.u32(UInt32(entry.data.count))
                + Self.u16(UInt16(name.count)) + Self.u16(0) + Self.u16(0) + Self.u16(0) + Self.u16(0) + Self.u32(0) + Self.u32(offset) + name
        }
        let directoryOffset = UInt32(output.count)
        output += central
        output += Self.u32(0x0605_4b50) + Self.u16(0) + Self.u16(0) + Self.u16(UInt16(entries.count)) + Self.u16(UInt16(entries.count))
            + Self.u32(UInt32(central.count)) + Self.u32(directoryOffset) + Self.u16(0)
        return Data(output)
    }

    /// Raw DEFLATE of `bytes`, or `nil` when the encoder fails.
    static func deflate(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: bytes.count + 1024)
        let written = bytes.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Array(output[0..<written])
    }

    static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func u32(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)] }
}
