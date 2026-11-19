import AppKit
import CoreGraphics

enum VerticalStitchError: LocalizedError {
    case inconsistentFrames
    case noOverlap
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .inconsistentFrames: "长截图帧尺寸不一致"
        case .noOverlap: "未能可靠识别滚动重叠区域"
        case .tooLarge: "长截图超过 8000 万像素安全上限"
        }
    }
}

enum VerticalStitcher {
    enum FrameMatch: Equatable { case unchanged, overlap(Int), unmatched }

    struct Accumulator {
        enum Update: Equatable { case unchanged, appended, unmatched, limitReached }
        private let first: CGImage
        private var upper: [CGImage] = []
        private var lower: [CGImage] = []
        private var topSample: Sample?
        private var bottomSample: Sample?
        private var previous: (sample: Sample, offset: Int)?
        private var topOffset = 0
        private var bottomOffset = 0
        private var totalHeight: Int
        var frameCount: Int { upper.count + lower.count + 1 }
        var pixelSize: CGSize { CGSize(width: first.width, height: totalHeight) }

        init(first: CGImage) {
            self.first = first
            topSample = sample(first)
            bottomSample = topSample
            previous = topSample.map { ($0, 0) }
            totalHeight = first.height
        }

        mutating func offer(_ frame: CGImage) -> Update {
            guard frame.width == first.width, frame.height == first.height,
                  let topSample, let bottomSample, let nextSample = sample(frame) else { return .unmatched }
            let downward = classify(bottomSample, nextSample)
            if downward == .unchanged {
                previous = (nextSample, bottomOffset)
                return .unchanged
            }
            if topSample.bytes == nextSample.bytes {
                previous = (nextSample, topOffset)
                return .unchanged
            }
            let extendsTop: Bool
            let overlap: Int
            if case .overlap(let rows) = downward {
                extendsTop = false
                overlap = rows
            } else {
                switch classify(nextSample, topSample) {
                case .overlap(let rows): extendsTop = true; overlap = rows
                case .unchanged:
                    previous = (nextSample, topOffset)
                    return .unchanged
                case .unmatched:
                    // Scrolling back over a captured interior is not a stitch gap.
                    if let previous {
                        let interiorOffset: Int?
                        switch classify(previous.sample, nextSample) {
                        case .unchanged: interiorOffset = previous.offset
                        case .overlap(let rows): interiorOffset = previous.offset + (frame.height - rows)
                        case .unmatched:
                            if case .overlap(let rows) = classify(nextSample, previous.sample) {
                                interiorOffset = previous.offset - (frame.height - rows)
                            } else { interiorOffset = nil }
                        }
                        if let interiorOffset, (topOffset...bottomOffset).contains(interiorOffset) {
                            self.previous = (nextSample, interiorOffset)
                            return .unchanged
                        }
                    }
                    return .unmatched
                }
            }
            let addition = frame.height - overlap
            guard Int64(frame.width) * Int64(totalHeight + addition) <= 80_000_000 else {
                return .limitReached
            }
            let rect = CGRect(x: 0, y: extendsTop ? 0 : overlap, width: frame.width, height: addition)
            guard let crop = frame.cropping(to: rect),
                  // A cropped CGImage may retain its entire display frame.
                  // Own just the new rows so small scroll steps use little memory.
                  let strip = try? assemble([crop]) else { return .limitReached }
            if extendsTop {
                upper.append(strip)
                self.topSample = nextSample
                topOffset -= addition
                previous = (nextSample, topOffset)
            } else {
                lower.append(strip)
                self.bottomSample = nextSample
                bottomOffset += addition
                previous = (nextSample, bottomOffset)
            }
            totalHeight += addition
            return .appended
        }

        func result() throws -> CGImage {
            if frameCount == 1 { return first }
            return try assemble(Array(upper.reversed()) + [first] + lower)
        }

        // Project the stitched strips directly into the thumbnail, without
        // allocating an export-sized bitmap for each update.
        func thumbnail(fitting limit: CGSize) -> CGImage? {
            let scale = min(1, limit.width / pixelSize.width, limit.height / pixelSize.height)
            guard scale > 0, scale.isFinite else { return nil }
            let width = max(1, Int((pixelSize.width * scale).rounded(.down)))
            let height = max(1, Int((pixelSize.height * scale).rounded(.down)))
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .medium
            var row = totalHeight
            var edge = height
            func draw(_ strip: CGImage) {
                row -= strip.height
                let nextEdge = Int((Double(row) * Double(height) / Double(totalHeight)).rounded())
                // Give adjacent strips a shared pixel boundary, without seams
                // caused by independently rounding each strip's height.
                if nextEdge < edge {
                    context.draw(strip, in: CGRect(x: 0, y: nextEdge, width: width, height: edge - nextEdge))
                    edge = nextEdge
                }
            }
            upper.reversed().forEach(draw)
            draw(first)
            lower.forEach(draw)
            return context.makeImage()
        }
    }

    static func stitch(_ frames: [CGImage]) throws -> CGImage {
        guard let first = frames.first, frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw VerticalStitchError.inconsistentFrames
        }
        var accumulator = Accumulator(first: first)
        for frame in frames.dropFirst() {
            switch accumulator.offer(frame) {
            case .unmatched: throw VerticalStitchError.noOverlap
            case .limitReached: throw VerticalStitchError.tooLarge
            case .unchanged, .appended: break
            }
        }
        return try accumulator.result()
    }

    private static func assemble(_ strips: [CGImage]) throws -> CGImage {
        guard let first = strips.first, strips.allSatisfy({ $0.width == first.width }) else {
            throw VerticalStitchError.inconsistentFrames
        }
        let totalHeight = strips.reduce(0) { $0 + $1.height }
        guard let context = CGContext(data: nil, width: first.width, height: totalHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VerticalStitchError.tooLarge
        }
        var y = totalHeight
        for strip in strips {
            y -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: y, width: first.width, height: strip.height))
        }
        guard let result = context.makeImage() else { throw VerticalStitchError.tooLarge }
        return result
    }

    static func findOverlap(previous: CGImage, next: CGImage) -> Int? {
        guard previous.width == next.width, previous.height == next.height,
              let a = sample(previous), let b = sample(next) else { return nil }
        switch classify(a, b) {
        case .unchanged: return previous.height
        case .overlap(let rows): return rows
        case .unmatched: return nil
        }
    }

    private static func classify(_ a: Sample, _ b: Sample) -> FrameMatch {
        let height = a.height
        if a.bytes == b.bytes { return .unchanged }
        guard height >= 24 else { return .unmatched }
        let fixedEdge = max(2, height / 10)
        let step = max(1, height / 72)
        func score(shift: Int) -> (difference: Double, signal: Double)? {
            let end = height - fixedEdge - shift
            guard end > fixedEdge else { return nil }
            var sum = 0
            var signal = 0
            var activeRows = 0
            for nextRow in stride(from: fixedEdge, to: end, by: step) {
                let firstRow = nextRow + shift
                let rowSignal = max(a.energy[firstRow], b.energy[nextRow])
                guard rowSignal >= 2 else { continue }
                activeRows += 1
                signal += rowSignal
                for x in stride(from: 4, to: a.width - 4, by: 4) {
                    let indexA = (firstRow * a.width + x) * 4
                    let indexB = (nextRow * b.width + x) * 4
                    for channel in 0..<3 {
                        sum += abs(Int(a.bytes[indexA + channel]) - Int(b.bytes[indexB + channel]))
                    }
                }
            }
            guard activeRows >= 5 else { return nil }
            return (Double(sum) / Double(activeRows * 42), Double(signal) / Double(activeRows))
        }
        let stationary = score(shift: 0)?.difference
        if let stationary, stationary <= 0.65 { return .unchanged }
        var best: (shift: Int, error: Double)?
        // Keep enough overlapping moving content to reject jumps and static bars.
        let limit = height - max(18, height / 3)
        for shift in 1...limit {
            guard let candidate = score(shift: shift),
                  candidate.difference <= max(2, min(12, candidate.signal * 0.75)),
                  stationary.map({ candidate.difference < $0 * 0.68 }) ?? true else { continue }
            let error = candidate.difference
            if best.map({ error < $0.error - 0.02 }) ?? true { best = (shift, error) }
        }
        guard let best else { return .unmatched }
        return best.shift <= 1 ? .unchanged : .overlap(height - best.shift)
    }

    private struct Sample {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let energy: [Int]
    }

    private static func sample(_ image: CGImage) -> Sample? {
        let width = 64
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        let energy = (0..<height).map { y -> Int in
            var sum = 0
            for x in stride(from: 4, to: width - 4, by: 4) {
                let i = (y * width + x) * 4
                let j = (max(0, y - 1) * width + x) * 4
                for channel in 0..<3 {
                    let value = Int(bytes[i + channel])
                    sum += max(abs(value - Int(bytes[i + channel + 4])), abs(value - Int(bytes[j + channel])))
                }
            }
            return sum / 42
        }
        return Sample(width: width, height: height, bytes: bytes, energy: energy)
    }

    static func verifySynthetic() -> Bool {
        let width = 96, height = 360
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        for y in 0..<height {
            let code = UInt32((y * 1_103_515_245 &+ 12_345) & 0xFFFFFF)
            context.setFillColor(LEStyle.color(code).cgColor)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        guard let world = context.makeImage(),
              let first = world.cropping(to: CGRect(x: 0, y: 0, width: width, height: 180)),
              let second = world.cropping(to: CGRect(x: 0, y: 105, width: width, height: 180)),
              let third = world.cropping(to: CGRect(x: 0, y: 180, width: width, height: 180)) else { return false }
        guard let result = try? stitch([first, second, third]),
              result.width == width, abs(result.height - height) <= 8 else { return false }
        // Start in the middle, stitch both directions, and compare the preview
        // at 1:1 with the actual export, including the rows at both joins.
        var collector = Accumulator(first: second)
        guard collector.offer(first) == .appended, collector.offer(third) == .appended,
              let exact = collector.thumbnail(fitting: collector.pixelSize),
              let export = try? collector.result(),
              let reduced = collector.thumbnail(fitting: CGSize(width: 70, height: 120)),
              reduced.height == 120, (30...34).contains(reduced.width),
              exact.height == export.height, sample(exact)?.bytes == sample(export)?.bytes else { return false }
        func withFixedBars(_ image: CGImage) -> CGImage? {
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.setFillColor(LEStyle.container.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: 16))
            context.fill(CGRect(x: 0, y: image.height - 16, width: image.width, height: 16))
            return context.makeImage()
        }
        guard let decoratedFirst = withFixedBars(first),
              let decoratedSecond = withFixedBars(second) else { return false }
        let decoratedOverlap = findOverlap(previous: decoratedFirst, next: decoratedSecond)
        guard let decoratedOverlap else { return false }
        return abs(decoratedOverlap - 75) <= 3
    }
}
