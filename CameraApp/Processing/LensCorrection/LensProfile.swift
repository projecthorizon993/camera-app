import Foundation

// Task 13 — lens correction profile model + JSON profile store (pure Foundation).

/// Provenance of a lens-correction profile.
enum Source: String, Sendable, CaseIterable {
    /// Parameters parsed live from the captured photo's DNG OpcodeList.
    case dngOpcodes = "dngOpcodes"
    /// Compiled-in profile loaded from the bundled LensProfiles JSON.
    case bundledJSON = "bundledJSON"
    /// Neutral identity placeholder.
    case neutral = "neutral"
}

/// Brown-Conrady radial distortion coefficients (k1, k2, k3).
struct LensProfile: Codable, Sendable, Equatable {
    let lensID: CameraLensID
    let distortion: DistortionCoefficients
    struct DistortionCoefficients: Codable, Sendable, Equatable {
        let k1: Float
        let k2: Float
        let k3: Float
    }
    let caOffsets: Float
    let vignetteGain: Float
    let source: Source
}

/// Loads compiled-in + runtime lens profiles. Capability-driven: missing
/// bundled file/lens → empty result, errors surfaced by callers (no crash).
enum LensProfileStore {

    /// Compiled-in profiles from CameraApp/Resources/LensProfiles/*.json.
    /// v1 ships ONE neutral identity profile for `.wide` (k = 0, ca = 0, gain = 1.0,
    /// source = .neutral) — real per-lens values populate when own-capture DNG
    /// opcode parsing runs on device (Task 20 integration) and T22b offline
    /// calibration lands.
    static func bundledProfiles() -> [LensProfile] {
        var profiles: [LensProfile] = []
        if let url = Bundle.main.url(forResource: "wide-neutral", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LensProfile.self, from: data) {
            profiles.append(decoded)
        }
        return profiles
    }

    /// Runtime cache (Application Support) written by `cacheParsedOnDeviceProfile`.
    /// Missing / undecodable cache → empty (fall back to bundled).
    static func cachedProfiles() -> [LensProfile] {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheURL = supportDirectory.appendingPathComponent("LensProfileCache.json")
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([LensProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Persists a parsed-from-DNG profile into Application Support as JSON
    /// (runtime calibration cache).
    static func cacheParsedOnDeviceProfile(_ profile: LensProfile) throws {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cacheURL = supportDirectory.appendingPathComponent("LensProfileCache.json")
        try JSONEncoder().encode(profile).write(to: cacheURL)
    }

    /// Merged profile list: runtime-cached entries override bundled ones
    /// (cache is written by the DNG-parse → calibrate pipeline at runtime).
    static func mergedProfiles() -> [LensProfile] {
        var merged = bundledProfiles()
        for cached in cachedProfiles() {
            merged.removeAll { $0.lensID == cached.lensID }
            merged.append(cached)
        }
        return merged
    }
}
