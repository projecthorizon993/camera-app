import Foundation
import CoreImage
import CoreVideo
import Metal
import os

// MARK: - LookError

enum LookError: Error {
    case lookNotLoaded
    case renderFailed(String)
}

// MARK: - LookEngine

/// Frozen-contract engine implementing `LookEngineProtocol`. Color grading is
/// produced from in-code `LookRecipe`s via a `CIColorCube` LUT, with a
/// strength slider that blends graded-over-original using `blendWithMask`.
final class LookEngine: LookEngineProtocol, @unchecked Sendable {

    // MARK: State

    private struct State {
        var loaded: LookID?
        var cache: [LookID: [Float]] = [:]
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Informational only — CoreImage picks its own device. Documented as unused
    /// for rendering decisions (PixelBufferBridge.makeImageContext handles fallback).
    private let device: MTLDevice?

    init() {
        device = MTLCreateSystemDefaultDevice()
    }

    // MARK: LookEngineProtocol

    var availableLooks: [LookID] { LookID.allCases }

    /// The currently loaded look (`.none` when nothing loaded).
    var currentLook: LookID {
        state.withLock { $0.loaded ?? .none }
    }

    func loadLook(_ id: LookID) throws {
        state.withLock { st in
            if st.cache[id] == nil {
                let recipe = LookRecipes.recipe(for: id)
                st.cache[id] = LookRecipes.cubeData(forRecipe: recipe, grid: 32)
            }
            st.loaded = id
        }
    }

    func apply(_ input: CVPixelBuffer, look: LookID, strength: Double) async throws -> CVPixelBuffer {
        // Fast paths: documented passthrough (mirrors the T13 contract behavior).
        if look == .none || strength <= 0 {
            return input
        }

        let clampedStrength = min(max(strength, 0), 1)

        // Cube cache (lazy generation guarded by the lock).
        let cube: [Float]
        let cached = state.withLock { $0.cache[look] }
        if let c = cached {
            cube = c
        } else {
            let recipe = LookRecipes.recipe(for: look)
            let generated = LookRecipes.cubeData(forRecipe: recipe, grid: 32)
            state.withLock { $0.cache[look] = generated }
            cube = generated
        }
        state.withLock { $0.loaded = look }

        // GPU hop: CoreImage work runs off the caller's actor; the buffer crosses
        // the boundary only inside PixelBufferBox (both directions).
        let inputBox = PixelBufferBox(buffer: input)
        let cubeData = cube

        let resultBox = try await Task.detached(priority: .userInitiated) { () throws -> PixelBufferBox in
            let src = inputBox.buffer
            let width = CVPixelBufferGetWidth(src)
            let height = CVPixelBufferGetHeight(src)
            let format = CVPixelBufferGetPixelFormatType(src)

            // Fresh output buffer — never the input (shared preview buffers are
            // read-only downstream).
            var output: CVPixelBuffer?
            let attrs = PixelBufferPool.pixelBufferAttributes as CFDictionary
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs, &output)
            guard status == kCVReturnSuccess, let outBuffer = output else {
                throw LookError.renderFailed("could not allocate output buffer")
            }

            let context = PixelBufferBridge.makeImageContext()
            let ciInput = CIImage(cvPixelBuffer: src)

            // ONE CIColorCube filter: inputCubeData from the recipe's cube.
            let cubePayload = cubeData.withUnsafeBytes { Data($0) }
            guard let colorCube = CIFilter.colorCube(withColorSpace: nil,
                                                    cubeDimension: 32,
                                                    cubeData: cubePayload) else {
                throw LookError.renderFailed("CIColorCube unavailable")
            }
            colorCube.setValue(ciInput, forKey: kCIInputImageKey)
            guard let graded = colorCube.outputImage else {
                throw LookError.renderFailed("CIColorCube produced no output")
            }

            // blendWithMask: graded over original, mask = gray of strength.
            // Result = graded * strength + original * (1 - strength) — an exact mix.
            let maskImage = CIImage(color: CIColor(gray: CGFloat(clampedStrength)))
                .cropped(to: ciInput.extent)
            guard let blender = CIFilter.blendWithMask() else {
                throw LookError.renderFailed("blendWithMask unavailable")
            }
            blender.setValue(graded, forKey: kCIInputImageKey)
            blender.setValue(ciInput, forKey: kCIInputBackgroundImageKey)
            blender.setValue(maskImage, forKey: kCIInputMaskImageKey)
            guard let blended = blender.outputImage else {
                throw LookError.renderFailed("blendWithMask produced no output")
            }

            context.render(blended, to: outBuffer, bounds: blended.extent, colorSpace: nil)
            return PixelBufferBox(buffer: outBuffer)
        }.value

        return resultBox.buffer
    }
}
