import Foundation

/// The response fixtures under `spec/`: read in place on the Mac, from this
/// file's own location, so a fixture added beside them needs no declaring;
/// carried as this target's resources for a device, which cannot see the
/// Mac's files, where a new folder of fixtures is listed in `Package.swift`.
public enum Spec {
    /// The fixtures, laid out as `spec/` is.
    public static let directory: URL = {
        #if os(macOS)
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        #else
        return Bundle.module.resourceURL ?? Bundle.module.bundleURL
        #endif
    }()

    /// The bytes of a fixture, by its path inside `spec/`:
    /// `rickandmorty/characters-page-1.json`.
    public static func data(_ path: String) -> Data {
        let url = directory.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Spec: cannot read \(url.path)")
        }
        return data
    }
}
