import Foundation

/// Decodes saved data written by an older (or newer) version of the app. Swift's synthesized
/// `Decodable` fails on any missing key, even for properties with default values, so a
/// field added later would make every older saved edit or settings blob fail to load
/// (the editor would silently drop all of a photo's sliders). This fills missing keys from
/// the type's own defaults and ignores unknown ones.
enum TolerantJSON {
    /// `saved` over `defaults`, recursing into nested objects present in both.
    static func merging(_ saved: [String: Any], over defaults: [String: Any]) -> [String: Any] {
        var out = defaults
        for (key, value) in saved {
            if let s = value as? [String: Any], let d = defaults[key] as? [String: Any] {
                out[key] = merging(s, over: d)
            } else {
                out[key] = value
            }
        }
        return out
    }

    static func object<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decodes `T` from `data`, with any key `data` lacks taken from `defaults`.
    /// `prepare` can adjust the saved object first (e.g. fill a nested optional's defaults).
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T,
                                   prepare: ([String: Any]) -> [String: Any] = { $0 }) -> T? {
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = object(defaults) else {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let merged = merging(prepare(saved), over: base)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: mergedData)
    }
}
