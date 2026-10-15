import CUnrar
import Foundation

/// Extracts a (multi-volume) RAR archive with RARLAB's UnRAR library.
///
/// Runs synchronously; call `extract` off the main thread. `cancel()` may be called
/// from any thread and stops at the next data block.
final class UnrarArchive: @unchecked Sendable {
    struct Entry: Sendable {
        var path: String
        var isDirectory: Bool
        var unpackedSize: Int64
    }

    enum UnrarError: LocalizedError {
        case library(code: Int32, archive: URL)
        case missingVolume(String)
        case canceled

        var errorDescription: String? {
            switch self {
            case let .library(code, archive):
                "\(Self.message(for: code)) (\(archive.lastPathComponent))"
            case let .missingVolume(name):
                String(localized: "Cannot open RAR volume \(name)")
            case .canceled:
                String(localized: "Canceled.")
            }
        }

        private static func message(for code: Int32) -> String {
            switch code {
            case ERAR_NO_MEMORY: String(localized: "Not enough memory")
            case ERAR_BAD_DATA: String(localized: "Invalid data or incorrect password")
            case ERAR_BAD_ARCHIVE: String(localized: "Invalid archive")
            case ERAR_UNKNOWN_FORMAT: String(localized: "Unknown archive format")
            case ERAR_EOPEN: String(localized: "Cannot open archive volume")
            case ERAR_ECREATE: String(localized: "Cannot create output file")
            case ERAR_ECLOSE: String(localized: "Cannot close archive")
            case ERAR_EREAD: String(localized: "Cannot read archive")
            case ERAR_EWRITE: String(localized: "Cannot write output file")
            case ERAR_MISSING_PASSWORD: String(localized: "Password required")
            case ERAR_BAD_PASSWORD: String(localized: "Incorrect password")
            default: String(localized: "Unrar error \(code)")
            }
        }
    }

    let url: URL
    /// Asked once per archive when an entry is encrypted. Return nil to give up.
    var passwordProvider: (@Sendable () -> String?)?
    /// Bytes unpacked so far and the total, for progress display.
    var progressHandler: (@Sendable (_ done: Int64, _ total: Int64, _ currentFile: String) -> Void)?
    var keepBrokenFiles = false

    private let lock = NSLock()
    private var canceled = false
    private var password: String?
    private var passwordAsked = false
    private var missingVolume: String?
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var currentFile = ""

    init(url: URL) {
        self.url = url
    }

    func cancel() {
        lock.withLock { canceled = true }
    }

    private var isCanceled: Bool { lock.withLock { canceled } }

    /// Lists the archive without extracting.
    func entries() throws -> [Entry] {
        var result: [Entry] = []
        try withOpenArchive(mode: UInt32(RAR_OM_LIST)) { handle in
            var header = RARHeaderDataEx()
            while true {
                let status = RARReadHeaderEx(handle, &header)
                if status == ERAR_END_ARCHIVE { break }
                guard status == ERAR_SUCCESS else { throw UnrarError.library(code: status, archive: url) }
                result.append(Entry(
                    path: Self.string(fromWide: &header.FileNameW),
                    isDirectory: header.Flags & UInt32(RHDF_DIRECTORY) != 0,
                    unpackedSize: Int64(header.UnpSizeHigh) << 32 | Int64(header.UnpSize)
                ))
                let skip = RARProcessFile(handle, RAR_SKIP, nil, nil)
                guard skip == ERAR_SUCCESS else { throw UnrarError.library(code: skip, archive: url) }
            }
        }
        return result
    }

    /// The top-level items the archive will produce.
    func topLevelItems() throws -> Set<String> {
        Set(try entries().compactMap { Self.topLevelItem(of: $0.path) })
    }

    /// UnRAR drops "." / ".." components and leading slashes when extracting; do the same,
    /// so a crafted name can never point at the destination's parent.
    static func topLevelItem(of path: String) -> String? {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .first { $0 != "." && $0 != ".." }
            .map(String.init)
    }

    /// Extracts everything into `destination`, which must exist.
    func extract(to destination: URL) throws {
        bytesTotal = try entries().filter { !$0.isDirectory }.reduce(0) { $0 + $1.unpackedSize }
        bytesDone = 0

        try withOpenArchive(mode: UInt32(RAR_OM_EXTRACT)) { handle in
            var header = RARHeaderDataEx()
            var destinationPath = Self.wide(destination.path)
            while true {
                if isCanceled { throw UnrarError.canceled }
                let status = RARReadHeaderEx(handle, &header)
                if status == ERAR_END_ARCHIVE { break }
                guard status == ERAR_SUCCESS else { throw failure(for: status) }
                currentFile = Self.string(fromWide: &header.FileNameW)

                let result = destinationPath.withUnsafeMutableBufferPointer {
                    RARProcessFileW(handle, RAR_EXTRACT, $0.baseAddress, nil)
                }
                if isCanceled { throw UnrarError.canceled }
                guard result == ERAR_SUCCESS else { throw failure(for: result) }
            }
        }
    }

    private func failure(for code: Int32) -> Error {
        if let missingVolume { return UnrarError.missingVolume(missingVolume) }
        return UnrarError.library(code: code, archive: url)
    }

    private func withOpenArchive(mode: UInt32, _ body: (UnsafeMutableRawPointer) throws -> Void) throws {
        var archiveName = Self.wide(url.path)
        let userData = Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())

        let handle: UnsafeMutableRawPointer? = archiveName.withUnsafeMutableBufferPointer { name in
            var data = RAROpenArchiveDataEx()
            data.ArcNameW = name.baseAddress
            data.OpenMode = mode
            data.Callback = { message, userData, p1, p2 in
                guard let pointer = UnsafeRawPointer(bitPattern: userData) else { return -1 }
                let archive = Unmanaged<UnrarArchive>.fromOpaque(pointer).takeUnretainedValue()
                return archive.handleCallback(message: message, p1: p1, p2: p2)
            }
            data.UserData = userData
            data.OpFlags = keepBrokenFiles ? UInt32(ROADOF_KEEPBROKEN) : 0
            let handle = RAROpenArchiveEx(&data)
            if data.OpenResult != ERAR_SUCCESS {
                return nil
            }
            return handle
        }
        guard let handle else {
            throw UnrarError.library(code: ERAR_EOPEN, archive: url)
        }
        defer { RARCloseArchive(handle) }
        try body(handle)
    }

    // MARK: - Callback

    fileprivate func handleCallback(message: UInt32, p1: Int, p2: Int) -> Int32 {
        switch message {
        case UInt32(UCM_PROCESSDATA.rawValue):
            bytesDone += Int64(p2)
            progressHandler?(bytesDone, bytesTotal, currentFile)
            return isCanceled ? -1 : 1

        case UInt32(UCM_NEEDPASSWORDW.rawValue):
            if !passwordAsked {
                passwordAsked = true
                password = passwordProvider?()
            }
            guard let password, let buffer = UnsafeMutablePointer<wchar_t>(bitPattern: p1) else { return -1 }
            let wide = Self.wide(password)
            guard wide.count <= p2 else { return -1 }
            buffer.update(from: wide, count: wide.count)
            return 1

        case UInt32(UCM_CHANGEVOLUMEW.rawValue):
            // RAR_VOL_ASK means the next volume does not exist.
            if p2 == RAR_VOL_ASK, let name = UnsafeMutablePointer<wchar_t>(bitPattern: p1) {
                missingVolume = (Self.string(fromWide: name) as NSString).lastPathComponent
                return -1
            }
            return 1

        default:
            return 0
        }
    }

    // MARK: - wchar_t conversion

    static func wide(_ string: String) -> [wchar_t] {
        string.unicodeScalars.map { wchar_t(bitPattern: $0.value) } + [0]
    }

    static func string(fromWide pointer: UnsafePointer<wchar_t>) -> String {
        var scalars = String.UnicodeScalarView()
        var index = 0
        while pointer[index] != 0 {
            if let scalar = Unicode.Scalar(UInt32(bitPattern: pointer[index])) {
                scalars.append(scalar)
            }
            index += 1
        }
        return String(scalars)
    }

    static func string<T>(fromWide tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: wchar_t.self, capacity: MemoryLayout<T>.size / MemoryLayout<wchar_t>.size) {
                string(fromWide: $0)
            }
        }
    }
}

