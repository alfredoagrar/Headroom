import Darwin
import Foundation

struct FileStamp: Sendable, Hashable {
    let size: UInt64
    let modified: Date
    let inode: UInt64?

    /// Attributes of the path itself (symlinks are not followed). For filtering only; reads go through `RegularFile`.
    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                         modified: attributes[.modificationDate] as? Date ?? .distantPast,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

/// Opens regular files only: no symlinks (`O_NOFOLLOW`), no FIFOs or devices (`fstat` check), so a planted
/// link can neither redirect a read nor block the collector. Size, inode and mtime come from the same descriptor.
final class RegularFile {
    let stamp: FileStamp
    private let fd: Int32

    init(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }
        self.fd = fd
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        stamp = FileStamp(size: UInt64(max(0, info.st_size)), modified: Date(timeIntervalSince1970: modified),
                          inode: UInt64(info.st_ino))
    }

    deinit { Darwin.close(fd) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while total < count {
                let n = pread(fd, base + total, count - total, off_t(offset) + off_t(total))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if n == 0 { break }
                total += n
            }
        }
        data.count = total
        return data
    }

    /// Whole file, or nil when it isn't a regular file or is larger than `maxBytes`.
    static func contents(of url: URL, maxBytes: Int) -> Data? {
        guard let file = try? RegularFile(url), file.stamp.size <= UInt64(maxBytes) else { return nil }
        return try? file.read(at: 0, count: Int(file.stamp.size))
    }

    /// First `maxBytes` of the file at most.
    static func head(of url: URL, maxBytes: Int) -> Data? {
        guard let file = try? RegularFile(url) else { return nil }
        return try? file.read(at: 0, count: Int(min(file.stamp.size, UInt64(maxBytes))))
    }
}

protocol JSONLConsumer {
    mutating func reset()
    mutating func consume(_ line: Data)
}

/// Incremental reader for append-only JSON Lines files. Lines are handed to the consumer and never retained.
/// Reads in fixed chunks and skips lines longer than `maxLineBytes`, so memory stays bounded for any file.
struct JSONLTail: Sendable {
    let chunkSize: Int
    let maxLineBytes: Int
    private(set) var offset: UInt64 = 0
    /// Stamp of the file as of the last read.
    private(set) var stamp: FileStamp?
    private var partial = Data()
    private var discarding = false

    init(chunkSize: Int = 8 << 20, maxLineBytes: Int = 32 << 20) {
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// Feeds complete lines appended since the last call. Starting over (first read, or the file was
    /// truncated or replaced) resets the consumer first. Unchanged files aren't read at all.
    mutating func drain<Consumer: JSONLConsumer>(_ url: URL, into consumer: inout Consumer) throws {
        let file = try RegularFile(url)
        let current = file.stamp
        guard current != stamp else { return }
        if current.inode != stamp?.inode || current.size < offset {
            offset = 0
            partial = Data()
            discarding = false
        }
        if offset == 0 { consumer.reset() }
        while offset < current.size {
            let chunk = try file.read(at: offset, count: Int(min(UInt64(chunkSize), current.size - offset)))
            guard !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            for line in split(chunk) { consumer.consume(line) }
        }
        stamp = current
    }

    private mutating func split(_ chunk: Data) -> [Data] {
        var buffer = chunk
        if !partial.isEmpty {
            buffer = partial
            buffer.append(chunk)
            partial = Data()
        }
        var start = buffer.startIndex
        if discarding {
            // Still inside an oversized line: drop everything up to its end.
            guard let newline = buffer.firstIndex(of: 0x0A) else { return [] }
            start = buffer.index(after: newline)
            discarding = false
        }
        var lines: [Data] = []
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(buffer[start..<newline]) }
            start = buffer.index(after: newline)
        }
        let rest = buffer.endIndex - start
        if rest > maxLineBytes {
            discarding = true
        } else if rest > 0 {
            partial = Data(buffer[start...])
        }
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

/// Token counts come from other apps' files: clamp them so arithmetic can't trap or go negative.
enum TokenCount {
    static let maxValue = 1 << 40

    static func clamp(_ value: Int?) -> Int { min(max(value ?? 0, 0), maxValue) }
}

extension Int {
    func saturatingAdd(_ other: Int) -> Int {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }
}
