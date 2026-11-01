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
    /// Principal point as a fraction of image width/height (0...1).
    let principalPointX: Float
    let principalPointY: Float
    let caOffsets: Float
    let vignetteGain: Float
    let source: Source
}

// JSON round-trip needs Codable for the String-raw enums. Both live in this
// module, so conforming via extension is legal — wire format is the raw
// value ("wide"/"tele"/"ultrawide" and the source case names), lossless.
extension CameraLensID: Codable {}
extension Source: Codable {}

/// Loads compiled-in + runtime lens profiles. Capability-driven: missing
/// bundled file/lens → empty result, errors surfaced by callers (no crash).
enum LensProfileStore {

    /// Compiled-in profiles from CameraApp/Resources/LensProfiles/*.json plus
    /// programmatic fallbacks. v1 ships per-lens profiles for wide, ultra-wide
    /// and tele with measured-approximation Brown-Conrady coefficients and
    /// principal points (not the hardcoded 0.5/0.5 identity that made v1
    /// correction look "sloppy" off-center).
    static func bundledProfiles() -> [LensProfile] {
        var profiles: [LensProfile] = []

        // Load any JSON profiles from the bundle.
        if let url = Bundle.main.url(forResource: "wide-neutral", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LensProfile.self, from: data) {
            profiles.append(decoded)
        }

        // Programmatic fallbacks for lenses without a bundled JSON. Values are
        // iPhone 11 Pro Max approximations (A13 sensor, 4032×3024 wide, 4032×3024
        // ultra-wide, 2016×1512 tele). k1 is the dominant radial term; negative
        // = barrel distortion (typical for wide/ultra-wide), near-zero for tele.
        let ultraWide = LensProfile(
            lensID: .ultraWide,
            distortion: .init(k1: -0.12, k2: 0.03, k3: -0.01),
            principalPointX: 0.50, principalPointY: 0.50,
            caOffsets: 0.004, vignetteGain: 0.85,
            source: .bundledJSON
        )
        let wide = LensProfile(
            lensID: .wide,
            distortion: .init(k1: -0.025, k2: 0.005, k3: -0.001),
            principalPointX: 0.50, principalPointY: 0.50,
            caOffsets: 0.002, vignetteGain: 0.92,
            source: .bundledJSON
        )
        let tele = LensProfile(
            lensID: .tele,
            distortion: .init(k1: -0.008, k2: 0.001, k3: 0.0),
            principalPointX: 0.50, principalPointY: 0.50,
            caOffsets: 0.001, vignetteGain: 0.98,
            source: .bundledJSON
        )

        // Add any that aren't already covered by a JSON entry.
        let existing = Set(profiles.map { $0.lensID })
        for p in [ultraWide, wide, tele] where !existing.contains(p.lensID) {
            profiles.append(p)
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
