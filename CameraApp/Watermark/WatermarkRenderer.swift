import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import CoreImage

// MARK: - WatermarkError

enum WatermarkError: Error, Sendable {
    case invalidInput
    case backdropUnavailable
    case textRenderFailed
}

// MARK: - WatermarkRenderer

/// @unchecked Sendable: all per-call state is method-local (no stored mutables
/// beyond the template list). CG/CoreText rendering is CPU work — hops off the
/// caller's actor via Task.detached, boxing buffers in BOTH directions
/// (PixelBufferBox — the proven T6/T12 pattern).
///
/// Orientation assumption: buffers arrive UPRIGHT (the capture pipeline's
/// orientation pass runs before processing stages). No rotation math here.
final class WatermarkRenderer: WatermarkRendererProtocol, ProcessingStageProtocol, @unchecked Sendable {

    let templates: [WatermarkTemplate]

    // MARK: ProcessingStageProtocol

    let stage: PipelineStage = .watermark

    init(templates: [WatermarkTemplate] = WatermarkLibrary.builtins) {
        self.templates = templates
    }

    var availableTemplates: [WatermarkTemplate] { templates }

    // MARK: Stage adapter

    func process(_ input: CVPixelBuffer, context: ProcessingContext) async throws -> CVPixelBuffer {
        let template = templates.first ?? WatermarkLibrary.builtins[0]
        return try await render(input, template: template, exif: context.exif,
                                position: .bottomCenter, opacity: 1.0)
    }

    // MARK: Render

    func render(_ input: CVPixelBuffer, template: WatermarkTemplate,
                exif: ExifSummary?, position: WatermarkPosition,
                opacity: Double) async throws -> CVPixelBuffer {
        if opacity < 0 {
            throw WatermarkError.invalidInput
        }
        if opacity == 0 {
            return input
        }

        // Degenerate: resolve lines; if nothing resolves, passthrough.
        let resolved = template.lines.compactMap {
            WatermarkPlanner.resolve(content: $0.content, exif: exif, metadata: [:])
        }
        if resolved.isEmpty {
            return input
        }

        let box = PixelBufferBox(buffer: input)
        let result = try await Task.detached(priority: .userInitiated) { [self] in
            try self.renderSync(box: box, template: template, exif: exif,
                               position: position, opacity: opacity)
        }.value
        return result.buffer
    }

    // MARK: Sync render

    private func renderSync(box: PixelBufferBox, template: WatermarkTemplate,
                            exif: ExifSummary?, position: WatermarkPosition,
                            opacity: Double) throws -> PixelBufferBox {
        let input = box.buffer
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let short = min(width, height)
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))

        let format = CVPixelBufferGetPixelFormatType(input)
        let isBGRA = (format == kCVPixelFormatType_32BGRA)

        let layout = WatermarkPlanner.layout(template: template, position: position, size: size)

        if isBGRA {
            let lockStatus = CVPixelBufferLockBaseAddress(input, [])
            guard lockStatus == kCVReturnSuccess else {
                throw WatermarkError.backdropUnavailable
            }
            defer { CVPixelBufferUnlockBaseAddress(input, []) }

            guard let base = CVPixelBufferGetBaseAddress(input) else {
                throw WatermarkError.backdropUnavailable
            }
            let bpr = CVPixelBufferGetBytesPerRow(input)
            guard let ctx = CGContext(data: base, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: bpr,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                                 | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw WatermarkError.backdropUnavailable
            }
            draw(into: ctx, template: template, layout: layout, size: size,
                 short: short, opacity: opacity, exif: exif)
            return PixelBufferBox(buffer: input)
        } else {
            // Non-BGRA: lock read-only, blit via CGImage/CoreImage round-trip,
            // then draw into the fresh 32BGRA buffer.
            let roFlag = kCVPixelBufferLock_ReadOnly
            CVPixelBufferLockBaseAddress(input, roFlag)
            let ciImage = CIImage(cvPixelBuffer: input)
            CVPixelBufferUnlockBaseAddress(input, roFlag)

            var output: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                            kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                            &output)
            guard status == kCVReturnSuccess, let outBuffer = output else {
                throw WatermarkError.backdropUnavailable
            }

            let ciContext = CIContext()
            ciContext.render(ciImage, to: outBuffer, bounds: ciImage.extent,
                             colorSpace: CGColorSpaceCreateDeviceRGB())

            let lock2 = CVPixelBufferLockBaseAddress(outBuffer, [])
            guard lock2 == kCVReturnSuccess else {
                throw WatermarkError.backdropUnavailable
            }
            defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

            guard let base2 = CVPixelBufferGetBaseAddress(outBuffer) else {
                throw WatermarkError.backdropUnavailable
            }
            let bpr2 = CVPixelBufferGetBytesPerRow(outBuffer)
            guard let ctx2 = CGContext(data: base2, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bpr2,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                                  | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw WatermarkError.backdropUnavailable
            }
            draw(into: ctx2, template: template, layout: layout, size: size,
                 short: short, opacity: opacity, exif: exif)
            return PixelBufferBox(buffer: outBuffer)
        }
    }

    // MARK: Drawing

    private func draw(into ctx: CGContext, template: WatermarkTemplate,
                      layout: WatermarkLayout, size: CGSize, short: Int,
                      opacity: Double, exif: ExifSummary?) {
        // Flip to top-left origin while keeping text upright.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Background bar.
        if template.backgroundBar, let barRect = layout.barRect {
            if let baseColor = WatermarkPlanner.color(fromHex: "000000") {
                ctx.setFillColor(baseColor.copy(alpha: CGFloat(opacity * 0.55)) ?? baseColor)
                ctx.fill(barRect)
            }
        }

        // Text lines.
        let textColorBase = WatermarkPlanner.color(fromHex: template.textColorHex)
            ?? CGColor(gray: 1, alpha: 1)
        let textColor = textColorBase.copy(alpha: CGFloat(opacity)) ?? textColorBase
        let fontName = "HelveticaNeue-Bold" as CFString

        for (index, line) in template.lines.enumerated() {
            guard index < layout.lineRects.count else { continue }
            let rect = layout.lineRects[index]
            guard let text = WatermarkPlanner.resolve(content: line.content, exif: exif,
                                                      metadata: [:]) else { continue }
            if rect.height <= 0 { continue }
            let fontSize = CGFloat(line.relativeFontSize * template.fontScale * Double(short))
            if fontSize <= 0 { continue }
            let ctFont = CTFontCreateWithName(fontName, fontSize, nil)

            let attrs: [CFString: Any] = [
                kCTFontAttributeName: ctFont,
                kCTForegroundColorAttributeName: textColor,
            ]
            guard let attrStr = CFAttributedStringCreate(nil, text as CFString,
                                                       attrs as CFDictionary) else {
                continue
            }
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

            let penX: CGFloat
            switch template.alignment {
            case .left:
                penX = rect.minX
            case .center:
                penX = rect.minX + (rect.width - lineWidth) / 2
            case .right:
                penX = rect.maxX - lineWidth
            }

            let ascent = CTFontGetAscent(ctFont)
            let descent = CTFontGetDescent(ctFont)
            let leading = CTFontGetLeading(ctFont)
            let textHeight = ascent + descent + leading
            let baselineY = rect.minY + (rect.height - textHeight) / 2 + ascent

            ctx.textPosition = CGPoint(x: penX, y: baselineY)
            CTLineDraw(ctLine, ctx)
        }

        // Divider.
        if let divider = template.divider, let drect = layout.dividerRect {
            if let dcolor = WatermarkPlanner.color(fromHex: divider.colorHex) {
                ctx.setStrokeColor(dcolor.copy(alpha: CGFloat(opacity)) ?? dcolor)
                ctx.setLineWidth(max(1, CGFloat(divider.thicknessFraction) * CGFloat(short)))
                ctx.move(to: CGPoint(x: drect.minX, y: drect.midY))
                ctx.addLine(to: CGPoint(x: drect.maxX, y: drect.midY))
                ctx.strokePath()
            }
        }
    }
}
