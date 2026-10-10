import Foundation

/// The response fixtures under `spec/`, carried as this target's resources,
/// so the tests and the benchmarks read them from the bundle they run in,
/// on a device as on the Mac, with no working directory involved.
public enum Spec {
    /// The fixtures, laid out as `spec/` is.
    public static let directory: URL = Bundle.module.resourceURL ?? Bundle.module.bundleURL

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
