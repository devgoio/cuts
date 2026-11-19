import AppKit
@preconcurrency import Vision

struct OCRGlyph {
    let text: String
    let box: CGRect // Vision coordinates: normalized, origin at the image's bottom left.
    let line: Int
}

struct OCRDocument {
    let glyphs: [OCRGlyph]

    func selectedText(from first: Int, through last: Int) -> String {
        guard glyphs.indices.contains(first), glyphs.indices.contains(last) else { return "" }
        let indices = min(first, last)...max(first, last)
        var result = ""
        var previousLine: Int?
        for index in indices {
            let glyph = glyphs[index]
            if let previousLine, previousLine != glyph.line { result += "\n" }
            result += glyph.text
            previousLine = glyph.line
        }
        return result
    }
}

enum OCRTextRecognition {
    static func recognize(_ image: CGImage, completion: @escaping (Result<OCRDocument, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                var glyphs: [OCRGlyph] = []
                for (line, observation) in (request.results ?? []).enumerated() {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let string = candidate.string
                    let count = max(1, string.count)
                    for (offset, index) in string.indices.enumerated() {
                        let next = string.index(after: index)
                        let candidateBox = (try? candidate.boundingBox(for: index..<next))?.boundingBox
                        let fallback = CGRect(x: observation.boundingBox.minX + observation.boundingBox.width * CGFloat(offset) / CGFloat(count),
                                              y: observation.boundingBox.minY,
                                              width: observation.boundingBox.width / CGFloat(count),
                                              height: observation.boundingBox.height)
                        let box = candidateBox.flatMap { value in
                            value.width > 0 && value.height > 0
                                && CGRect(x: 0, y: 0, width: 1, height: 1).intersects(value) ? value : nil
                        } ?? fallback
                        glyphs.append(OCRGlyph(text: String(string[index..<next]), box: box, line: line))
                    }
                }
                let document = OCRDocument(glyphs: glyphs)
                DispatchQueue.main.async { completion(.success(document)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
