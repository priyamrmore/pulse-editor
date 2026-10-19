import AVFoundation
import ImageIO
import NitroModules
import UniformTypeIdentifiers

/// Frames as JPEGs: `AVAssetImageGenerator` reading through a video composition built with merge's
/// own geometry (`MergeGeometry`), so an edited clip's frames are drawn exactly as the export
/// renders it, and HDR is tone-mapped to BT.709 the same way. Scaled to fit the maximum size,
/// never up. `run` takes one exact frame (a cover); `frames` takes several from one generator (a
/// filmstrip), each the nearest keyframe within the tolerance when one is given.
enum FrameGrab {
  /// A generator set up for one file and edit, and what's needed to place times inside its video.
  struct Prepared {
    let generator: AVAssetImageGenerator
    let range: CMTimeRange
    let frame: CMTime

    /// `ms` (from the video's start) as a time inside it: past the last frame is the last frame.
    func time(_ ms: Double) -> CMTime {
      let lastFrame = range.end - frame
      return CMTimeMaximum(range.start, CMTimeMinimum(
        range.start + CMTime(value: CMTimeValue(max(0, ms).rounded()), timescale: 1000), lastFrame))
    }
  }

  static func prepare(
    _ uri: String, rotation: Double, flipped: Bool, crop: MergeCrop?,
    maxWidth: Double, maxHeight: Double
  ) async throws -> Prepared {
    let media = try await Probe.load(fileURL(uri))
    guard let track = media.videoTrack else { throw MergeError.invalid("The file has no video.") }
    let (size, transform, range, minFrame) = try await track.load(
      .naturalSize, .preferredTransform, .timeRange, .minFrameDuration)
    let frame = minFrame.isNumeric && minFrame > .zero ? minFrame : CMTime(value: 1, timescale: 30)

    let clip = MergeClip(
      uri: uri, startMs: 0, endMs: 0, speed: 1, muted: false,
      rotation: rotation, flipped: flipped, crop: crop)
    // The edited picture's size first, then the output: that size fitted into the maximum.
    let content = MergeGeometry(
      clip: clip, sourceSize: size, sourceTransform: transform,
      targetSize: size, targetTransform: .identity, canvas: size).contentSize
    let output = fitted(content, maxWidth: maxWidth, maxHeight: maxHeight)
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
    composition.frameDuration = frame
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

    let generator = AVAssetImageGenerator(asset: media.asset)
    generator.videoComposition = composition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return Prepared(generator: generator, range: range, frame: frame)
  }

  static func run(_ uri: String, _ options: ThumbnailOptions) async throws -> Thumbnail {
    let prepared = try await prepare(
      uri, rotation: options.rotation, flipped: options.flipped, crop: options.crop,
      maxWidth: options.maxWidth, maxHeight: options.maxHeight)
    let wanted = prepared.time(options.timeMs)
    let image: CGImage
    var actual = CMTime.zero
    if #available(iOS 16, *) {
      (image, actual) = try await prepared.generator.image(at: wanted)
    } else {
      image = try prepared.generator.copyCGImage(at: wanted, actualTime: &actual)
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
      timeMs: Probe.ms(actual - prepared.range.start))
  }

  /// Several frames from one generator, in the order asked, for a filmstrip: read straight from
  /// the video (upright, decoded small), then the clip's edit drawn on each little picture —
  /// clockwise rotation, horizontal flip, crop, as merge applies them. Without a video composition
  /// the generator can take the nearest keyframe within `toleranceMs` (a composition makes every
  /// frame exact, about 150 ms each on an iPhone 17 Pro Max), and it gets every time at once
  /// (`images(for:)`, in source order), so it decodes forward through the file. HDR frames aren't
  /// tone-mapped as merge does: fine for a filmstrip, not for a cover (`run`).
  static func frames(_ uri: String, _ options: FramesOptions) async throws -> [Frame] {
    let media = try await Probe.load(fileURL(uri))
    guard let track = media.videoTrack else { throw MergeError.invalid("The file has no video.") }
    let (range, minFrame) = try await track.load(.timeRange, .minFrameDuration)
    let frame = minFrame.isNumeric && minFrame > .zero ? minFrame : CMTime(value: 1, timescale: 30)
    let prepared = Prepared(generator: AVAssetImageGenerator(asset: media.asset), range: range, frame: frame)
    let generator = prepared.generator
    generator.appliesPreferredTrackTransform = true
    // Decoded just big enough that the cropped part still fills the maximum, whichever way the
    // picture is turned (the generator keeps the aspect inside this square).
    let crop = options.crop
    let zoom = 1 / max(0.05, min(crop?.w ?? 1, crop?.h ?? 1))
    let side = max(options.maxWidth, options.maxHeight)
    if side > 0 { generator.maximumSize = CGSize(width: side * zoom, height: side * zoom) }
    let tolerance = CMTime(value: CMTimeValue(max(0, options.toleranceMs).rounded()), timescale: 1000)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    let quality = min(max(options.quality, 0), 1)

    let order = options.timesMs.indices.sorted { options.timesMs[$0] < options.timesMs[$1] }
    let times = order.map { prepared.time(options.timesMs[$0]) }
    var out = [Frame?](repeating: nil, count: options.timesMs.count)
    func keep(_ k: Int, _ upright: CGImage, _ actual: CMTime) throws {
      let i = order[k]
      let image = edited(upright, options)
      out[i] = Frame(
        timeMs: options.timesMs[i], actualMs: Probe.ms(actual - range.start),
        width: Double(image.width), height: Double(image.height),
        data: try jpegBuffer(image, quality))
    }
    if #available(iOS 16, *) {
      var next = 0
      for await result in generator.images(for: times) {
        try Task.checkCancellation()
        // Results come back in the order asked; match each by its requested time anyway.
        var k = next
        while k < times.count && times[k] != result.requestedTime { k += 1 }
        if k == times.count { k = next }
        next = k + 1
        try keep(k, try result.image, (try? result.actualTime) ?? times[k])
      }
    } else {
      for k in times.indices {
        try Task.checkCancellation()
        var actual = CMTime.zero
        try keep(k, try generator.copyCGImage(at: times[k], actualTime: &actual), actual)
      }
    }
    return out.compactMap { $0 }
  }

  /// An upright frame with the clip's edit drawn (clockwise rotation, then a horizontal flip, then
  /// the crop, normalized in the turned and flipped picture), fitted into the maximum.
  private static func edited(_ image: CGImage, _ options: FramesOptions) -> CGImage {
    let degrees = ((Int(options.rotation.rounded()) % 360) + 360) % 360
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    var turned = image
    if degrees != 0 || options.flipped {
      let quarter = degrees == 90 || degrees == 270
      let size = quarter ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
      // CoreGraphics is y-up: a clockwise turn on screen maps (x, y) to these.
      let rotate: CGAffineTransform
      switch degrees {
      case 90: rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
      case 180: rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
      case 270: rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
      default: rotate = .identity
      }
      let flip = options.flipped
        ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0) : .identity
      if let context = bitmap(size) {
        context.concatenate(rotate.concatenating(flip))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let made = context.makeImage() { turned = made }
      }
    }
    if let c = options.crop {
      let tw = CGFloat(turned.width)
      let th = CGFloat(turned.height)
      // CGImage cropping is in pixels from the top left, as the crop is.
      let rect = CGRect(x: c.x * tw, y: c.y * th, width: c.w * tw, height: c.h * th).integral
      if let cropped = turned.cropping(to: rect) { turned = cropped }
    }
    let out = fitted(
      CGSize(width: turned.width, height: turned.height),
      maxWidth: options.maxWidth, maxHeight: options.maxHeight)
    if Int(out.width) >= turned.width && Int(out.height) >= turned.height { return turned }
    guard let context = bitmap(out) else { return turned }
    context.interpolationQuality = .medium
    context.draw(turned, in: CGRect(origin: .zero, size: out))
    return context.makeImage() ?? turned
  }

  private static func bitmap(_ size: CGSize) -> CGContext? {
    CGContext(
      data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
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
