import Foundation

struct FileStamp: Sendable, Hashable {
    let size: UInt64
    let modified: Date
    let inode: UInt64?

    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: attributes[.modificationDate] as? Date ?? .distantPast,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

/// Incremental reader for append-only JSON Lines files. Lines are handed to the caller and never retained.
struct JSONLTail: Sendable {
    private(set) var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()

    /// Reads complete lines appended since the last call. `fromStart` is true when reading began at
    /// offset 0 (first read, or the file was truncated or replaced) — callers reset their totals then.
    mutating func readNewLines(at url: URL, stamp: FileStamp) throws -> (lines: [Data], fromStart: Bool) {
        if stamp.inode != inode || stamp.size < offset {
            offset = 0
            partial = Data()
            inode = stamp.inode
        }
        let fromStart = offset == 0
        guard stamp.size > offset else { return ([], fromStart) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let chunk = try handle.read(upToCount: Int(stamp.size - offset)) ?? Data()
        offset += UInt64(chunk.count)
        return (split(chunk), fromStart)
    }

    private mutating func split(_ chunk: Data) -> [Data] {
        var buffer = partial
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(buffer[start..<newline]) }
            start = buffer.index(after: newline)
        }
        partial = Data(buffer[start...])
        return lines
    }
}

extension Data {
    func hasMarker(_ marker: Data) -> Bool { range(of: marker) != nil }
}

extension KeyedDecodingContainer {
    /// Decodes a field if present and of the expected type; anything else becomes `nil` instead of
    /// failing the whole line (these formats are undocumented and change without notice).
    func lenient<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}
