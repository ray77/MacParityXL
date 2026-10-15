import Foundation

/// Recognizes the naming schemes of multi-volume RAR archives.
public enum RarVolumes {
    /// Whether the file starts an archive, i.e. is what Unrar should be pointed at.
    ///
    /// - `name.rar` (with `name.r00`, `name.r01`, …)
    /// - `name.part1.rar` / `name.part01.rar` (RAR 3+)
    /// - `name.exe` / `name.part01.exe` (self-extracting)
    /// - `name.001` (split files)
    public static func isFirstVolume(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if let part = partNumber(lower) {
            return part == 1
        }
        if lower.hasSuffix(".rar") || lower.hasSuffix(".exe") {
            return true
        }
        return lower.hasSuffix(".001")
    }

    /// Whether the file belongs to a RAR archive at all.
    public static func isVolume(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".rar") || lower.hasSuffix(".001") { return true }
        let ext = (lower as NSString).pathExtension
        return ext.count == 3 && ext.first == "r" && ext.dropFirst().allSatisfy(\.isNumber)
    }

    /// All files in `fileNames` that belong to the archive starting at `firstVolume`.
    public static func segments(of firstVolume: String, in fileNames: [String]) -> [String] {
        let lower = firstVolume.lowercased()
        if let range = lower.range(of: #"\.part0*1\.(rar|exe)$"#, options: .regularExpression) {
            let base = lower[..<range.lowerBound]
            return fileNames.filter {
                let candidate = $0.lowercased()
                return candidate.hasPrefix(base + ".part") && partNumber(candidate) != nil
            }
        }
        let base = (lower as NSString).deletingPathExtension
        return fileNames.filter {
            let candidate = $0.lowercased()
            guard (candidate as NSString).deletingPathExtension == base else { return false }
            let ext = (candidate as NSString).pathExtension
            if ext == "rar" || ext == "exe" { return true }
            if ext.count == 3, ext.first == "r", ext.dropFirst().allSatisfy(\.isNumber) { return true }
            return ext.count == 3 && ext.allSatisfy(\.isNumber)
        }
    }

    private static func partNumber(_ lower: String) -> Int? {
        guard let match = lower.range(of: #"\.part[0-9]+\.(rar|exe)$"#, options: .regularExpression) else { return nil }
        let digits = lower[match].dropFirst(5).prefix(while: \.isNumber)
        return Int(digits)
    }
}

extension Array where Element == String {
    /// Sorted the way Finder sorts names (`a.2` before `a.10`).
    public func finderSorted() -> [String] {
        sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
