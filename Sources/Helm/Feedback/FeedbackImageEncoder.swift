import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Encodes a `UIImage` as JPEG small enough to upload with feedback.
///
/// The size search is separate from UIKit (`fit(maxBytes:longestSide:encode:)`
/// takes the encoder as a closure) so it can be unit-tested on any platform.
internal enum FeedbackImageEncoder {

    /// JPEG qualities tried at full size, best first.
    static let qualities: [Double] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4]

    /// Each scale-down step multiplies the width and height by this factor.
    static let scaleStep = 0.75

    /// Scaling stops before the longest side drops below this many pixels;
    /// a smaller screenshot is no longer useful to read.
    static let minimumLongestSide = 320.0

    /// Find the first encoding that is at most `maxBytes`.
    ///
    /// First tries each quality in `qualities` at full size. If none fits, it
    /// keeps the lowest quality and scales the image down by `scaleStep` until
    /// it fits or the longest side would drop below `minimumLongestSide`.
    ///
    /// - Parameters:
    ///   - maxBytes: The largest allowed result.
    ///   - longestSide: The image's longest side in pixels at full size.
    ///   - encode: Encodes the image at a JPEG quality (0...1) and a scale
    ///     factor (1 is full size). Returns `nil` when encoding fails.
    /// - Throws: `HelmFeedbackError.invalidImage` when encoding fails, or
    ///   `.imageTooLarge` when no attempt fits.
    static func fit(maxBytes: Int,
                    longestSide: Double,
                    encode: (_ quality: Double, _ scale: Double) -> Data?) throws -> Data {
        for quality in qualities {
            guard let data = encode(quality, 1.0) else {
                throw HelmFeedbackError.invalidImage(message: "The image could not be encoded as JPEG.")
            }
            if data.count <= maxBytes {
                return data
            }
        }

        let lowestQuality = qualities.last ?? 0.4
        var scale = scaleStep
        while longestSide * scale >= minimumLongestSide {
            guard let data = encode(lowestQuality, scale) else {
                throw HelmFeedbackError.invalidImage(message: "The image could not be encoded as JPEG.")
            }
            if data.count <= maxBytes {
                return data
            }
            scale *= scaleStep
        }

        throw HelmFeedbackError.imageTooLarge(maxBytes: maxBytes)
    }

    #if canImport(UIKit)
    /// Encode `image` as JPEG of at most `maxBytes`, lowering the quality and
    /// then the size as needed. See `fit(maxBytes:longestSide:encode:)`.
    static func jpegData(for image: UIImage, maxBytes: Int) throws -> Data {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw HelmFeedbackError.invalidImage(message: "The image is empty.")
        }

        return try fit(maxBytes: maxBytes,
                       longestSide: Double(max(pixelWidth, pixelHeight))) { quality, scale in
            if scale == 1.0 {
                return image.jpegData(compressionQuality: CGFloat(quality))
            }
            let target = CGSize(width: max(1, (pixelWidth * CGFloat(scale)).rounded()),
                                height: max(1, (pixelHeight * CGFloat(scale)).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return resized.jpegData(compressionQuality: CGFloat(quality))
        }
    }
    #endif
}
