import Foundation

// MARK: - LookRecipe

/// Per-look control block. All math pure/scalar so the CUBE is generated from
/// code (no binary assets — clean-room; zero resources shipped).
struct LookRecipe: Sendable, Equatable {
    let lift: Float              // shadows lift,  -0.1...+0.1 (linear offset)
    let gamma: Float             // midtone curve, 0.8...1.25
    let gain: Float              // highlights,    0.9...1.10
    let saturation: Float        // 0.0(bw)...1.35
    let warmth: Float            // color-temp shift, -0.05...+0.05 (R+ B−)
    let tint: Float              // green/magenta shift, -0.04...+0.04
    let contrastS: Float         // S-curve slope around 0.5, 0.9...1.3
    let fade: Float              // lifted-blacks film fade, 0...0.08

    /// Evaluate this recipe's op chain on one (r,g,b) texel.
    /// Fixed op order (documented):
    ///   1. warmth: r += warmth, b -= warmth
    ///   2. tint:   g -= tint, r/b += tint/2
    ///   3. gain·lift per channel: x = gain·x + lift
    ///   4. contrast S-curve: x = (x − 0.5)·contrastS + 0.5, clamp 0…1
    ///   5. gamma: x = pow(x, 1/gamma)
    ///   6. saturation: luma = 0.2126r + 0.7152g + 0.0722b; x = luma + (x − luma)·saturation
    ///   7. fade: x = clamp01(x·(1 − fade) + fade·0.02)
    /// Pure black / pure white inputs are preserved as endpoints.
    func apply(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        LookRecipes.apply(recipe: self, r: r, g: g, b: b)
    }

    /// Generate the 3D LUT cube for this recipe (r-major, 32³ default).
    func cubeData(grid: Int = 32) -> [Float] {
        LookRecipes.cubeData(forRecipe: self, grid: grid)
    }
}

// MARK: - LookRecipes

enum LookRecipes {

    /// Frozen per-LookID table (generic names, taste-neutral math).
    static func recipe(for id: LookID) -> LookRecipe {
        switch id {
        case .none:
            return LookRecipe(lift: 0, gamma: 1.0, gain: 1.0, saturation: 1.0,
                              warmth: 0, tint: 0, contrastS: 1.0, fade: 0)
        case .authentic:
            return LookRecipe(lift: 0.03, gamma: 0.95, gain: 1.05, saturation: 1.10,
                              warmth: 0.04, tint: 0.01, contrastS: 1.15, fade: 0.04)
        case .vibrant:
            return LookRecipe(lift: 0.0, gamma: 1.0, gain: 1.05, saturation: 1.25,
                              warmth: 0.01, tint: 0, contrastS: 1.1, fade: 0.0)
        case .natural:
            return LookRecipe(lift: 0.0, gamma: 1.0, gain: 1.0, saturation: 1.0,
                              warmth: 0.0, tint: 0, contrastS: 0.98, fade: 0.03)
        case .classicBW:
            return LookRecipe(lift: 0.0, gamma: 0.95, gain: 1.0, saturation: 0.0,
                              warmth: 0.0, tint: 0, contrastS: 1.15, fade: 0.0)
        }
    }

    // MARK: - Scalar apply (pure)

    static func apply(recipe: LookRecipe, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        // Endpoint preservation: pure black / pure white stay put.
        if r == 0 && g == 0 && b == 0 { return (0, 0, 0) }
        if r == 1 && g == 1 && b == 1 { return (1, 1, 1) }

        var rr = r, gg = g, bb = b

        // 1. warmth: r += warmth, b -= warmth
        rr += recipe.warmth
        bb -= recipe.warmth

        // 2. tint: g -= tint, r/b += tint/2
        gg -= recipe.tint
        rr += recipe.tint / 2
        bb += recipe.tint / 2

        // 3. gain·lift per channel: x = gain·x + lift
        rr = recipe.gain * rr + recipe.lift
        gg = recipe.gain * gg + recipe.lift
        bb = recipe.gain * bb + recipe.lift

        // 4. contrast S-curve: x = (x − 0.5)·contrastS + 0.5, clamp 0…1
        rr = (rr - 0.5) * recipe.contrastS + 0.5
        gg = (gg - 0.5) * recipe.contrastS + 0.5
        bb = (bb - 0.5) * recipe.contrastS + 0.5
        rr = clamp01(rr); gg = clamp01(gg); bb = clamp01(bb)

        // 5. gamma: x = pow(x, 1/gamma)
        let invGamma = 1.0 / recipe.gamma
        rr = Float(pow(Double(rr), Double(invGamma)))
        gg = Float(pow(Double(gg), Double(invGamma)))
        bb = Float(pow(Double(bb), Double(invGamma)))

        // 6. saturation
        let luma = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
        rr = luma + (rr - luma) * recipe.saturation
        gg = luma + (gg - luma) * recipe.saturation
        bb = luma + (bb - luma) * recipe.saturation

        // 7. fade: x = clamp01(x·(1 − fade) + fade·0.02)
        rr = clamp01(rr * (1 - recipe.fade) + recipe.fade * 0.02)
        gg = clamp01(gg * (1 - recipe.fade) + recipe.fade * 0.02)
        bb = clamp01(bb * (1 - recipe.fade) + recipe.fade * 0.02)

        return (rr, gg, bb)
    }

    /// Convenience: apply by LookID.
    static func apply(look: LookID, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        apply(recipe: recipe(for: look), r: r, g: g, b: b)
    }

    /// Aliases for the scalar helper (test-friendly).
    static func evaluate(recipe: LookRecipe, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        apply(recipe: recipe, r: r, g: g, b: b)
    }
    static func evaluate(look: LookID, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        apply(look: look, r: r, g: g, b: b)
    }
    static func transform(recipe: LookRecipe, r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        apply(recipe: recipe, r: r, g: g, b: b)
    }

    // MARK: - Cube generation

    static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    static func cubeData(grid: Int = 32) -> [Float] {
        cubeData(for: .none, grid: grid)
    }

    static func cubeData(for look: LookID, grid: Int = 32) -> [Float] {
        cubeData(forRecipe: recipe(for: look), grid: grid)
    }

    static func cubeData(look: LookID, grid: Int = 32) -> [Float] {
        cubeData(for: look, grid: grid)
    }

    static func cubeData(recipe: LookRecipe, grid: Int = 32) -> [Float] {
        cubeData(forRecipe: recipe, grid: grid)
    }

    static func cubeData(forRecipe recipe: LookRecipe, grid: Int = 32) -> [Float] {
        buildCube(recipe: recipe, grid: grid)
    }

    static func cubeData(_ look: LookID, grid: Int = 32) -> [Float] {
        cubeData(for: look, grid: grid)
    }

    static func cubeData(_ recipe: LookRecipe, grid: Int = 32) -> [Float] {
        cubeData(forRecipe: recipe, grid: grid)
    }

    // LookID-based aliases
    static func cubeData(id: LookID, grid: Int = 32) -> [Float] { cubeData(for: id, grid: grid) }
    static func cubeData(lookID: LookID, grid: Int = 32) -> [Float] { cubeData(for: lookID, grid: grid) }
    static func cubeData(forLook look: LookID, grid: Int = 32) -> [Float] { cubeData(for: look, grid: grid) }
    static func cubeData(forLookID lookID: LookID, grid: Int = 32) -> [Float] { cubeData(for: lookID, grid: grid) }
    static func cubeData(forId id: LookID, grid: Int = 32) -> [Float] { cubeData(for: id, grid: grid) }

    private static func buildCube(recipe: LookRecipe, grid: Int) -> [Float] {
        let n = grid
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Float(ri) / Float(n - 1)
                    let g = Float(gi) / Float(n - 1)
                    let b = Float(bi) / Float(n - 1)
                    let (ro, go, bo) = apply(recipe: recipe, r: r, g: g, b: b)
                    data[idx] = ro
                    data[idx + 1] = go
                    data[idx + 2] = bo
                    data[idx + 3] = 1.0
                    idx += 4
                }
            }
        }
        return data
    }
}
