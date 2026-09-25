import Darwin
import Foundation

/// A file operation that failed: which step, and the errno it failed with.
struct DurableFileError: Error, Equatable {
    let step: String
    let code: Int32
}

/// Reading and replacing a small file so that a crash at any moment leaves
/// either the old contents or the new ones on disk, never a mixture.
enum DurableFile {

    enum ReadResult: Equatable {
        /// The file does not exist (ENOENT). Nothing else counts as missing.
        case missing
        case contents(Data)
        /// Any other failure, with its errno. A symlink in place of the file is
        /// one of these: it is never followed.
        case failed(Int32)
    }

    /// Reads the whole file without following a symlink at its path.
    static func read(_ url: URL) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            return code == ENOENT ? .missing : .failed(code)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failed(EINVAL) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return .contents(data)
    }

    /// Replaces the file at `url` with `data`, mode 0600: a temporary file in
    /// the same directory is written, flushed to the disk itself
    /// (`F_FULLFSYNC`), renamed over the target, and then the directory is
    /// synchronized so the rename itself survives a power loss.
    ///
    /// Throws `DurableFileError`. When it throws before the rename, the old
    /// file is untouched.
    static func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")

        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DurableFileError(step: "create", code: errno) }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }

        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw DurableFileError(step: "chmod", code: errno) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw DurableFileError(step: "write", code: errno)
                    }
                    offset += written
                }
            }
            guard fcntl(fd, F_FULLFSYNC) != -1 else { throw DurableFileError(step: "fullfsync", code: errno) }
        }

        guard rename(temporary.path, url.path) == 0 else { throw DurableFileError(step: "rename", code: errno) }
        renamed = true

        let dirFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard dirFD >= 0 else { throw DurableFileError(step: "open directory", code: errno) }
        defer { close(dirFD) }
        guard fsync(dirFD) == 0 else { throw DurableFileError(step: "sync directory", code: errno) }
    }
}

/// The folder play sync keeps its journal and lock in. It must belong to the
/// current user, be a real directory (not a symlink), and be mode 0700.
enum PrivateDirectory {

    /// Creates the directory, mode 0700, when it does not exist yet. An existing
    /// path that is not private is refused, never repaired: true only when the
    /// directory is private and usable.
    static func prepare(_ url: URL) -> Bool {
        let path = url.path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { return false }
            let parent = url.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                return false
            }
            if mkdir(path, 0o700) == 0 {
                // Only a directory this call created is given its mode; the
                // process umask never widens it, but may narrow it.
                guard chmod(path, 0o700) == 0 else { return false }
            } else if errno != EEXIST {
                return false
            }
            guard lstat(path, &info) == 0 else { return false }
        }
        return isPrivate(info)
    }

    /// A real directory, owned by this user, mode exactly 0700.
    static func isPrivate(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && (info.st_mode & 0o777) == 0o700
    }
}
