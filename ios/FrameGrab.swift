import AVFoundation
import ImageIO
import NitroModules
import UniformTypeIdentifiers

/// Frames as JPEGs. `run` takes one (a cover): `AVAssetImageGenerator` reading through a video
/// composition built with merge's own geometry (`MergeGeometry`), so an edited clip's cover is
/// drawn exactly as the export renders it, and HDR is tone-mapped to BT.709 the same way; the exact
/// frame at the requested time, scaled to fit the maximum size, never up. `frames` takes several
/// for a filmstrip, the file's own pictures (see there).
enum FrameGrab {
  static func run(_ uri: String, _ options: ThumbnailOptions) async throws -> Thumbnail {
    let media = try await Probe.load(fileURL(uri))
    guard let track = media.videoTrack else { throw MergeError.invalid("The file has no video.") }
    let (size, transform, range, frame) = try await track.load(
      .naturalSize, .preferredTransform, .timeRange, .minFrameDuration)

    let clip = MergeClip(
      uri: uri, startMs: 0, endMs: 0, speed: 1, muted: false,
      rotation: options.rotation, flipped: options.flipped, crop: options.crop)
    // The edited picture's size first, then the output: that size fitted into the maximum.
    let content = MergeGeometry(
      clip: clip, sourceSize: size, sourceTransform: transform,
      targetSize: size, targetTransform: .identity, canvas: size).contentSize
    let output = fitted(content, maxWidth: options.maxWidth, maxHeight: options.maxHeight)
    let geometry = MergeGeometry(
      clip: clip, sourceSize: size, sourceTransform: transform,
      targetSize: output, targetTransform: .identity, canvas: output)

    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(geometry.transform, at: .zero)
    if let crop = geometry.sourceCrop { layer.setCropRectangle(crop, at: .zero) }
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, end: range.end)
    instruction.layerInstructions = [layer]
    let composition = AVMutableVideoComposition()
    composition.instructions = [instruction]
    composition.renderSize = output
    composition.frameDuration = frameDuration(frame)
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    let generator = AVAssetImageGenerator(asset: media.asset)
    generator.videoComposition = composition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let wanted = time(options.timeMs, in: range, frame: frameDuration(frame))
    let image: CGImage
    var actual = CMTime.zero
    if #available(iOS 16, *) {
      (image, actual) = try await generator.image(at: wanted)
    } else {
      image = try generator.copyCGImage(at: wanted, actualTime: &actual)
    }

    let url = try Merge.outputURL("frame", extension: "jpg")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MergeError.failed("Couldn't create the image file.")
    }
    let quality = min(max(options.quality, 0), 1)
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      try? FileManager.default.removeItem(at: url)
      throw MergeError.failed("Couldn't write the image file.")
    }
    return Thumbnail(
      uri: url.absoluteString, width: Double(image.width), height: Double(image.height),
      timeMs: Probe.ms(actual - range.start))
  }

  /// Several frames from one generator, in the order asked, for a filmstrip: the file's own
  /// pictures, upright and unedited (the app draws a clip's edit on them), decoded small. Without
  /// a video composition the generator can take the nearest keyframe within `toleranceMs` (a
  /// composition makes every frame exact, about 150 ms each on an iPhone 17 Pro Max), and it gets
  /// every time at once (`images(for:)`, in source order), so it decodes forward through the file.
  /// A time that can't be decoded is left out; the rest still come. HDR frames aren't tone-mapped
  /// as merge does: fine for a filmstrip, not for a cover (`run`).
  static func frames(_ uri: String, _ options: FramesOptions) async throws -> [Frame] {
    let media = try await Probe.load(fileURL(uri))
    guard let track = media.videoTrack else { throw MergeError.invalid("The file has no video.") }
    let (range, minFrame) = try await track.load(.timeRange, .minFrameDuration)
    let frame = frameDuration(minFrame)
    let generator = AVAssetImageGenerator(asset: media.asset)
    generator.appliesPreferredTrackTransform = true
    // Decoded to fit a square of the larger side (the generator keeps the aspect, never scales
    // up); a box that isn't square is fitted after.
    let side = max(options.maxWidth, options.maxHeight)
    if side > 0 { generator.maximumSize = CGSize(width: side, height: side) }
    let tolerance = CMTime(value: CMTimeValue(max(0, options.toleranceMs).rounded()), timescale: 1000)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    let quality = min(max(options.quality, 0), 1)

    // In source order (one forward pass); results go back to the order asked.
    let order = options.timesMs.indices.sorted { options.timesMs[$0] < options.timesMs[$1] }
    let times = order.map { time(options.timesMs[$0], in: range, frame: frame) }
    var out = [Frame?](repeating: nil, count: times.count)
    var answered = [Bool](repeating: false, count: times.count)
    func keep(_ k: Int, _ upright: CGImage, _ actual: CMTime) {
      let i = order[k]
      let image = scaled(upright, maxWidth: options.maxWidth, maxHeight: options.maxHeight)
      guard let data = try? jpegBuffer(image, quality) else { return }
      out[i] = Frame(
        timeMs: options.timesMs[i], actualMs: Probe.ms(actual - range.start),
        width: Double(image.width), height: Double(image.height), data: data)
    }
    if #available(iOS 16, *) {
      for await result in generator.images(for: times) {
        // The first time not answered yet that this result is for (times clamped to the video's
        // end can repeat).
        guard let k = times.indices.first(where: { !answered[$0] && times[$0] == result.requestedTime })
        else { continue }
        answered[k] = true
        guard let image = try? result.image else { continue }
        keep(k, image, (try? result.actualTime) ?? times[k])
      }
    } else {
      for k in times.indices {
        var actual = CMTime.zero
        guard let image = try? generator.copyCGImage(at: times[k], actualTime: &actual) else { continue }
        keep(k, image, actual)
      }
    }
    return out.compactMap { $0 }
  }

  /// `ms` (from the video's start) as a time inside it: past the last frame is the last frame.
  private static func time(_ ms: Double, in range: CMTimeRange, frame: CMTime) -> CMTime {
    CMTimeMaximum(range.start, CMTimeMinimum(
      range.start + CMTime(value: CMTimeValue(max(0, ms).rounded()), timescale: 1000), range.end - frame))
  }

  /// A track's frame duration, or 1/30 s when it doesn't say.
  private static func frameDuration(_ min: CMTime) -> CMTime {
    min.isNumeric && min > .zero ? min : CMTime(value: 1, timescale: 30)
  }

  /// `image` fitted inside maxWidth × maxHeight (never up); itself when it already fits.
  private static func scaled(_ image: CGImage, maxWidth: Double, maxHeight: Double) -> CGImage {
    let out = fitted(CGSize(width: image.width, height: image.height), maxWidth: maxWidth, maxHeight: maxHeight)
    if Int(out.width) >= image.width && Int(out.height) >= image.height { return image }
    guard let context = CGContext(
      data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(origin: .zero, size: out))
    return context.makeImage() ?? image
  }

  /// `image` as JPEG bytes, in memory.
  private static func jpegBuffer(_ image: CGImage, _ quality: Double) throws -> ArrayBuffer {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw MergeError.failed("Couldn't encode the frame.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MergeError.failed("Couldn't encode the frame.") }
    return try ArrayBuffer.copy(data: data as Data)
  }

  /// `size` scaled down (never up) to fit inside maxWidth × maxHeight; 0 means no limit.
  static func fitted(_ size: CGSize, maxWidth: Double, maxHeight: Double) -> CGSize {
    var scale = 1.0
    if maxWidth > 0 { scale = min(scale, maxWidth / size.width) }
    if maxHeight > 0 { scale = min(scale, maxHeight / size.height) }
    return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
  }
}
