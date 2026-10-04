import Foundation

/// The response fixtures under `spec/`, read in place for the tests and the
/// benchmarks. The path comes from this file's own location at build time, so
/// neither a working directory nor a copy of the files is involved.
public enum Spec {
    /// The repository's `spec/` directory.
    public static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("spec", isDirectory: true)

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
