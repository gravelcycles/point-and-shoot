import Compression
import Foundation

/// Just enough ZIP for RAW archives: writes entries uncompressed ("stored"; DNGs barely
/// compress) and streams them to disk, and reads stored or deflated entries (so a zip
/// re-saved by Files or the Mac still imports). No ZIP64: an archive must stay under 4 GB.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case tooLarge, notAZip, unsupported(String), corrupt(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge: "The archive would be over 4 GB. Archive fewer photos at a time."
            case .notAZip: "That file isn't a zip archive."
            case .unsupported(let why): "Unsupported zip: \(why)."
            case .corrupt(let why): "The archive is damaged: \(why)."
            }
        }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            crcTable.withUnsafeBufferPointer { table in
                for byte in buf {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }

    // MARK: Writing

    /// Writes `files` (path inside the zip → file on disk) to `url`.
    static func write(_ files: [(path: String, source: URL)], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var central = Data()
        var offset: UInt64 = 0
        let (dosTime, dosDate) = dosDateTime(Date())

        for file in files {
            let data = try Data(contentsOf: file.source, options: .mappedIfSafe)
            guard offset + UInt64(data.count) < UInt64(UInt32.max) - 1_000_000 else { throw ZipError.tooLarge }
            let name = Data(file.path.utf8)
            let crc = crc32(data)
            var local = Data()
            local.append(le32: 0x0403_4B50)
            local.append(le16: 20)          // version needed
            local.append(le16: 0x0800)      // UTF-8 names
            local.append(le16: 0)           // stored
            local.append(le16: dosTime)
            local.append(le16: dosDate)
            local.append(le32: crc)
            local.append(le32: UInt32(data.count))
            local.append(le32: UInt32(data.count))
            local.append(le16: UInt16(name.count))
            local.append(le16: 0)
            local.append(name)
            try out.write(contentsOf: local)
            try out.write(contentsOf: data)

            central.append(le32: 0x0201_4B50)
            central.append(le16: 20)        // made by
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: dosTime)
            central.append(le16: dosDate)
            central.append(le32: crc)
            central.append(le32: UInt32(data.count))
            central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)         // extra
            central.append(le16: 0)         // comment
            central.append(le16: 0)         // disk
            central.append(le16: 0)         // internal attrs
            central.append(le32: 0)         // external attrs
            central.append(le32: UInt32(offset))
            central.append(name)
            offset += UInt64(local.count + data.count)
        }
        guard offset + UInt64(central.count) < UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = Data()
        end.append(le32: 0x0605_4B50)
        end.append(le16: 0)
        end.append(le16: 0)
        end.append(le16: UInt16(files.count))
        end.append(le16: UInt16(files.count))
        end.append(le32: UInt32(central.count))
        end.append(le32: UInt32(offset))
        end.append(le16: 0)
        try out.write(contentsOf: central)
        try out.write(contentsOf: end)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    // MARK: Reading

    struct Entry {
        let path: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    /// The archive's table of contents.
    static func entries(of data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip }
        // End of central directory: search backwards (a comment may follow it).
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while i >= floor {
            if data.le32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(data.le16(at: eocd + 10))
        var p = Int(data.le32(at: eocd + 16))
        if data.le32(at: eocd + 16) == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= data.count, data.le32(at: p) == 0x0201_4B50 else { throw ZipError.corrupt("directory") }
            let method = data.le16(at: p + 10)
            let crc = data.le32(at: p + 16)
            let csize = Int(data.le32(at: p + 20))
            let size = Int(data.le32(at: p + 24))
            let nameLen = Int(data.le16(at: p + 28))
            let extraLen = Int(data.le16(at: p + 30))
            let commentLen = Int(data.le16(at: p + 32))
            let local = Int(data.le32(at: p + 42))
            guard p + 46 + nameLen <= data.count else { throw ZipError.corrupt("name") }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen)], as: UTF8.self)
            out.append(Entry(path: name, method: method, crc: crc, compressedSize: csize, size: size, localOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// One entry's bytes, checked against its CRC.
    static func extract(_ e: Entry, from data: Data) throws -> Data {
        let p = e.localOffset
        guard p + 30 <= data.count, data.le32(at: p) == 0x0403_4B50 else { throw ZipError.corrupt(e.path) }
        let start = p + 30 + Int(data.le16(at: p + 26)) + Int(data.le16(at: p + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt(e.path) }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        let bytes: Data
        switch e.method {
        case 0:
            bytes = raw
        case 8:
            bytes = try inflate(raw, size: e.size)
        default:
            throw ZipError.unsupported("compression method \(e.method)")
        }
        guard crc32(bytes) == e.crc else { throw ZipError.corrupt("checksum of \(e.path)") }
        return bytes
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt("deflate") }
        return out
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func le16(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func le32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
}
