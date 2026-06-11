// OCR fallback via the Vision framework: reads on-screen text (with
// screenshot-pixel boxes) out of a window capture, for apps whose
// accessibility tree is missing or empty — custom-drawn UIs, games,
// remote-desktop and virtualization windows.

import CoreGraphics
import Foundation
import Vision

struct OCRLine: Sendable {
    let text: String
    /// x, y, w, h in screenshot pixels (top-left origin).
    let box: [Int]
}

func recognizeText(inPNG pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(data: pngData)
    // Vision's perform is synchronous CPU work; keep it off the caller.
    return try await Task.detached(priority: .userInitiated) {
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                box: pixelBox(normalized: observation.boundingBox, width: pixelWidth, height: pixelHeight)
            )
        }
    }.value
}

/// Vision boxes are normalized with a bottom-left origin; screenshots use
/// top-left pixel coordinates.
func pixelBox(normalized: CGRect, width: Int, height: Int) -> [Int] {
    [
        Int((normalized.minX * Double(width)).rounded()),
        Int(((1 - normalized.maxY) * Double(height)).rounded()),
        Int((normalized.width * Double(width)).rounded()),
        Int((normalized.height * Double(height)).rounded()),
    ]
}
