import AVFoundation
import CoreML
import Metal
import SceneKit
import UIKit
import Vision

// MARK: - The downloadable depth model

/// Depth Anything V2 Small (Core ML, Apache-2.0, published by Apple). It is not shipped with
/// the app: the とびだす form is "added" by downloading it once, then it is compiled on the
/// phone and kept in Application Support.
final class DepthModelStore: @unchecked Sendable {
  static let shared = DepthModelStore()
  private static let base =
    "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage/"
  private static let files = [
    "Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin",
  ]
  private let lock = NSLock()
  private var downloading = false
  private var progressSource: Progress?
  private var stage = 0.0
  private var failure: String?
  private var model: VNCoreMLModel?

  private var folder: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("DepthModel", isDirectory: true)
  }
  var compiledURL: URL? { folder?.appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc", isDirectory: true) }
  var isReady: Bool { compiledURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

  /// ready / downloading (with 0...1) / failed / absent
  func status() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    if isReady { return ["state": "ready"] }
    if downloading {
      let fraction = progressSource?.fractionCompleted ?? 0
      return ["state": "downloading", "progress": min(0.99, stage + fraction * 0.9)]
    }
    if let failure { return ["state": "failed", "message": failure] }
    return ["state": "absent", "megabytes": 50]
  }

  func download(completion: @escaping (Result<Void, Error>) -> Void) {
    lock.lock()
    if isReady { lock.unlock(); completion(.success(())); return }
    if downloading { lock.unlock(); completion(.success(())); return }
    downloading = true
    failure = nil
    stage = 0
    lock.unlock()
    Task.detached(priority: .userInitiated) {
      do {
        try await self.fetchAndCompile()
        self.finish(nil)
        completion(.success(()))
      } catch {
        self.finish("\(error.localizedDescription)")
        completion(.failure(error))
      }
    }
  }

  private func finish(_ message: String?) {
    lock.lock()
    downloading = false
    progressSource = nil
    failure = message
    lock.unlock()
  }

  private func fetchAndCompile() async throws {
    guard let folder, let compiledURL else { throw DepthModelError("no storage") }
    let fm = FileManager.default
    let package = folder.appendingPathComponent("DepthAnythingV2SmallF16.mlpackage", isDirectory: true)
    try? fm.removeItem(at: package)
    for file in Self.files {
      let target = package.appendingPathComponent(file)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard let url = URL(string: Self.base + file) else { throw DepthModelError("bad url") }
      let temp: URL = try await withCheckedThrowingContinuation { continuation in
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
          if let error { continuation.resume(throwing: error); return }
          guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
            continuation.resume(throwing: DepthModelError("download failed"))
            return
          }
          // the system removes `location` when this returns, so keep it first
          let kept = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          do {
            try fm.moveItem(at: location, to: kept)
            continuation.resume(returning: kept)
          } catch { continuation.resume(throwing: error) }
        }
        self.lock.lock(); self.progressSource = task.progress; self.lock.unlock()
        task.resume()
      }
      try fm.moveItem(at: temp, to: target)
    }
    lock.lock(); stage = 0.9; progressSource = nil; lock.unlock()
    let compiled = try await MLModel.compileModel(at: package)
    try? fm.removeItem(at: compiledURL)
    try fm.moveItem(at: compiled, to: compiledURL)
    try? fm.removeItem(at: package)
  }

  /// The loaded model, or nil when it has not been downloaded (the cards then stay flat).
  func loadedModel() -> VNCoreMLModel? {
    lock.lock(); defer { lock.unlock() }
    if let model { return model }
    guard let url = compiledURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    model = try? VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
    return model
  }
}

private struct DepthModelError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

// MARK: - Height maps

/// Turns one picture into a small height map: the subject rises out of the card to about a
/// real head's depth, its background and edges stay on the card.
final class WindowHeightMaps {
  static let columns = 54, rows = 72
  private let model: VNCoreMLModel?
  private var cache: [String: [Float]] = [:]
  private var order: [String] = []

  init(model: VNCoreMLModel?) { self.model = model }

  func heights(for image: CGImage, key: String) -> [Float]? {
    if let hit = cache[key] { return hit }
    guard let model else { return nil }
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .scaleFill
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
      let observation = request.results?.first as? VNPixelBufferObservation,
      let raw = Self.read(observation.pixelBuffer)
    else { return nil }
    let shaped = Self.shape(raw.values, width: raw.width, height: raw.height)
    cache[key] = shaped
    order.append(key)
    if order.count > 240 { cache.removeValue(forKey: order.removeFirst()) }
    return shaped
  }

  private static func read(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    var values = [Float](repeating: 0, count: width * height)
    switch CVPixelBufferGetPixelFormatType(buffer) {
    case kCVPixelFormatType_OneComponent8:
      for y in 0..<height {
        let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width { values[y * width + x] = Float(line[x]) }
      }
    case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
      for y in 0..<height {
        let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt16.self)
        for x in 0..<width { values[y * width + x] = Self.half(line[x]) }
      }
    case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
      for y in 0..<height {
        let line = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
        for x in 0..<width { values[y * width + x] = line[x] }
      }
    case kCVPixelFormatType_OneComponent16:
      for y in 0..<height {
        let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt16.self)
        for x in 0..<width { values[y * width + x] = Float(line[x]) }
      }
    default:
      return nil
    }
    return (values, width, height)
  }

  /// IEEE half to float, without Float16 (not available on every simulator architecture).
  private static func half(_ bits: UInt16) -> Float {
    let sign: Float = bits & 0x8000 == 0 ? 1 : -1
    let exponent = Int((bits >> 10) & 0x1F), fraction = Float(bits & 0x3FF)
    if exponent == 0 { return sign * fraction * pow(2, -24) }
    if exponent == 31 { return fraction == 0 ? sign * .infinity : .nan }
    return sign * (1 + fraction / 1024) * pow(2, Float(exponent - 15))
  }

  /// Same steps as the promo film's depth.py: normalise, split subject from background,
  /// let only the face (the near part of the subject) rise, sink the edges into the card.
  static func shape(_ values: [Float], width: Int, height: Int) -> [Float] {
    let gw = columns, gh = rows
    var grid = [Float](repeating: 0, count: gw * gh)
    for j in 0..<gh {
      for i in 0..<gw {
        let x = min(width - 1, Int((Float(i) + 0.5) / Float(gw) * Float(width)))
        let y = min(height - 1, Int((Float(j) + 0.5) / Float(gh) * Float(height)))
        grid[j * gw + i] = values[y * width + x]
      }
    }
    let sorted = grid.sorted()
    let lo = sorted[Int(Float(sorted.count - 1) * 0.02)], hi = sorted[Int(Float(sorted.count - 1) * 0.995)]
    let span = max(1e-6, hi - lo)
    grid = grid.map { min(1, max(0, ($0 - lo) / span)) }
    // Otsu split between background and subject
    var histogram = [Float](repeating: 0, count: 64)
    for v in grid { histogram[min(63, Int(v * 64))] += 1 }
    var best = 0.4, bestScore: Float = -1
    let total = Float(grid.count)
    var weight: Float = 0, sum: Float = 0
    let all = histogram.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * $1.element }
    for k in 0..<63 {
      weight += histogram[k]; sum += Float(k) * histogram[k]
      guard weight > 0, weight < total else { continue }
      let a = sum / weight, b = (all - sum) / (total - weight)
      let score = weight * (total - weight) * (a - b) * (a - b)
      if score > bestScore { bestScore = score; best = Double(k + 1) / 64 }
    }
    let cut = Float(best)
    func ramp(_ v: Float) -> Float { let c = min(1, max(0, v)); return c * c * (3 - 2 * c) }
    for j in 0..<gh {
      for i in 0..<gw {
        let u = Float(i) / Float(gw - 1), v = Float(j) / Float(gh - 1)
        let border = ramp(u / 0.2) * ramp((1 - u) / 0.2) * ramp(v / 0.16) * ramp((1 - v) / 0.2)
        let rise = min(1, max(0, (grid[j * gw + i] - cut) / max(1e-3, 1 - cut)))
        let face = min(1, max(0, (rise - 0.3) / 0.7))
        grid[j * gw + i] = face * border
      }
    }
    for _ in 0..<2 {   // soften
      var next = grid
      for j in 1..<(gh - 1) {
        for i in 1..<(gw - 1) {
          var s: Float = 0
          for dj in -1...1 { for di in -1...1 { s += grid[(j + dj) * gw + i + di] } }
          next[j * gw + i] = s / 9
        }
      }
      grid = next
    }
    return grid
  }
}

// MARK: - The とびだす frame

/// Every sound is a white card standing in a calm 3D space; what it filmed leans out of the
/// card like someone looking out of a window. Only sounding cards move (sway, hop, frames
/// advance); silent ones hold their last frame. A light slowly sweeps across them.
final class WindowFrameRenderer {
  private let width: Int, height: Int
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let renderer: SCNRenderer
  private let scene = SCNScene()
  private let camera = SCNNode()
  private let sun = SCNNode()
  private let backdrop: SCNNode
  private let color: MTLTexture, depth: MTLTexture
  private let images: CIContext
  /// what went wrong in the last frame, for tests and logs
  private(set) var lastProblem: String?
  let formats: String
  private let hasStencil: Bool
  private let heights: WindowHeightMaps
  private var cards: [String: WindowCard] = [:]

  init?(width: Int, height: Int, ground: CGColor) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
    self.width = width
    self.height = height
    self.device = device
    self.queue = queue
    let scn = SCNRenderer(device: device, options: nil)
    renderer = scn
    // drawn at twice the size and scaled down: smooth edges without multisampling,
    // which SceneKit's offscreen renderer does not accept
    // use exactly the formats SceneKit's pipelines are built for
    let colorFormat = scn.colorPixelFormat == .invalid ? MTLPixelFormat.bgra8Unorm_srgb : scn.colorPixelFormat
    let depthFormat = scn.depthPixelFormat == .invalid ? MTLPixelFormat.depth32Float : scn.depthPixelFormat
    let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width * 2, height: height * 2, mipmapped: false)
    target.usage = [.renderTarget, .shaderRead]
    target.storageMode = .private
    guard let color = device.makeTexture(descriptor: target) else { return nil }
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat, width: width * 2, height: height * 2, mipmapped: false)
    depthDescriptor.usage = .renderTarget
    depthDescriptor.storageMode = .private
    guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
    self.color = color
    self.depth = depth
    formats = "color=\(colorFormat.rawValue) depth=\(depthFormat.rawValue)"
    hasStencil = depthFormat == .depth32Float_stencil8
    images = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
    heights = WindowHeightMaps(model: DepthModelStore.shared.loadedModel())

    scene.background.contents = UIColor(cgColor: ground)
    let lens = SCNCamera()
    lens.fieldOfView = 30
    lens.zNear = 0.1
    lens.zFar = 100
    camera.camera = lens
    scene.rootNode.addChildNode(camera)
    renderer.scene = scene
    renderer.pointOfView = camera

    let light = SCNLight()
    light.type = .directional
    light.intensity = 900
    light.castsShadow = true
    light.shadowRadius = 10
    light.shadowSampleCount = 16
    light.shadowMapSize = CGSize(width: 2048, height: 2048)
    light.shadowColor = UIColor(white: 0.1, alpha: 0.28)
    light.orthographicScale = 6
    sun.light = light
    scene.rootNode.addChildNode(sun)
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light?.type = .ambient
    fill.light?.intensity = 520
    scene.rootNode.addChildNode(fill)

    let wall = SCNPlane(width: 40, height: 40)
    wall.firstMaterial?.diffuse.contents = UIColor(cgColor: ground)
    wall.firstMaterial?.lightingModel = .lambert
    backdrop = SCNNode(geometry: wall)
    backdrop.position = SCNVector3(0, 0, -0.35)
    scene.rootNode.addChildNode(backdrop)
  }

  private static let beatSamples = 22_500   // 128 BPM at 48 kHz
  private static let grounds: [UIColor] = [
    UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1), UIColor(red: 0.99, green: 0.89, blue: 0.88, alpha: 1),
    UIColor(red: 0.92, green: 0.90, blue: 0.99, alpha: 1), UIColor(red: 0.89, green: 0.96, blue: 0.93, alpha: 1),
    UIColor(red: 0.99, green: 0.94, blue: 0.86, alpha: 1), UIColor(red: 0.89, green: 0.93, blue: 0.99, alpha: 1),
  ]

  /// Card centres and sizes on the z = 0 plane, plus how far the camera must stand back.
  static func layout(count: Int, aspect: CGFloat) -> (cards: [CGRect], distance: Float) {
    let columns = count <= 2 ? 1 : 2
    let rows = (count + columns - 1) / columns
    let cardW: CGFloat = count == 1 ? 1.9 : 1.2, cardH = cardW * 4 / 3
    let gapX: CGFloat = 0.42, gapY: CGFloat = 0.36
    let totalW = CGFloat(columns) * cardW + CGFloat(columns - 1) * gapX
    let totalH = CGFloat(rows) * cardH + CGFloat(rows - 1) * gapY
    var cards: [CGRect] = []
    for index in 0..<count {
      let column = index % columns, row = index / columns
      let inRow = min(columns, count - row * columns)
      let rowW = CGFloat(inRow) * cardW + CGFloat(inRow - 1) * gapX
      let x = -rowW / 2 + CGFloat(column) * (cardW + gapX) + cardW / 2
      let y = totalH / 2 - CGFloat(row) * (cardH + gapY) - cardH / 2
      cards.append(CGRect(x: x - cardW / 2, y: y - cardH / 2, width: cardW, height: cardH))
    }
    let half = tan(15 * Float.pi / 180)
    let fitH = Float(totalH + 0.9) / (2 * half)
    let fitW = Float(totalW + 0.7) / (2 * half * Float(aspect))
    return (cards, max(fitH, fitW))
  }

  func draw(frame: Int, cards keyed: [(key: String, image: CGImage?, frameKey: String, playing: Bool, age: Int, punch: CGFloat)],
    into buffer: CVPixelBuffer) throws {
    let t = Float(frame) / 30
    let sample = frame * 1600
    let plan = Self.layout(count: max(1, keyed.count), aspect: CGFloat(width) / CGFloat(height))
    // a small push on every beat, and a new pastel ground every two bars
    let intoBeat = Float(sample % Self.beatSamples) / 48_000
    let push = exp(-intoBeat * 9)
    camera.camera?.fieldOfView = CGFloat(30 - push * 1.1)
    camera.position = SCNVector3(sin(t * 0.35) * 0.6, 0.15 + sin(t * 0.23) * 0.2, plan.distance)
    camera.look(at: SCNVector3(0, 0, 0))
    let ground = Self.grounds[(sample / (Self.beatSamples * 8)) % Self.grounds.count]
    scene.background.contents = ground
    backdrop.geometry?.firstMaterial?.diffuse.contents = ground
    // the light sweeps slowly from one side to the other and back
    sun.eulerAngles = SCNVector3(-0.55, sin(t * 0.9) * 0.75, 0)
    let live = Set(keyed.map(\.key))
    for (key, card) in cards where !live.contains(key) { card.root.removeFromParentNode(); cards.removeValue(forKey: key) }
    for (index, item) in keyed.enumerated() {
      let rect = plan.cards[min(index, plan.cards.count - 1)]
      let card = cards[item.key] ?? {
        let made = WindowCard(width: Float(rect.width), height: Float(rect.height))
        scene.rootNode.addChildNode(made.root)
        cards[item.key] = made
        return made
      }()
      card.root.position = SCNVector3(Float(rect.midX), Float(rect.midY), 0)
      if let image = item.image {
        card.show(image: image, heights: heights.heights(for: image, key: item.frameKey))
      }
      let seconds = Float(item.age) / 48_000
      let p = Float(item.punch)
      let sway = item.playing ? sin(t * 2.3 + Float(index)) * 0.42 : sin(t * 0.7 + Float(index)) * 0.1
      card.tilt.eulerAngles = SCNVector3(-0.05, sway, item.playing ? sin(seconds * 9) * 0.03 * p : 0)
      let hop = item.playing ? max(0, sin(min(1, seconds / 0.22) * Float.pi)) : 0
      card.tilt.position = SCNVector3(0, hop * 0.16, p * 0.08)
      card.tilt.scale = SCNVector3(1 + 0.06 * p, 1 - 0.09 * p, 1)
      card.setDimmed(!item.playing)
    }
    // SceneKit draws the frame itself (with 4x multisampling); we only copy it into the video
    let shot = renderer.snapshot(atTime: TimeInterval(t), with: CGSize(width: width, height: height),
      antialiasingMode: .multisampling4X)
    guard let picture = shot.cgImage else {
      lastProblem = "snapshot had no image"
      throw VideoRenderError.writerFailed
    }
    lastProblem = nil
    images.render(CIImage(cgImage: picture), to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
  }
}

/// One sound: a white frame, the flat picture inside it, and the raised front layer that leans
/// out over the frame.
private final class WindowCard {
  let root = SCNNode()
  let tilt = SCNNode()
  private let photo: SCNMaterial
  private let shell = SCNNode()
  private let shellMaterial = SCNMaterial()
  private let w: Float, h: Float
  private var lastImage: CGImage?

  init(width: Float, height: Float) {
    w = width; h = height
    root.addChildNode(tilt)
    let frame = SCNBox(width: CGFloat(width + 0.12), height: CGFloat(height + 0.12), length: 0.08, chamferRadius: 0.05)
    frame.firstMaterial?.diffuse.contents = UIColor.white
    frame.firstMaterial?.lightingModel = .physicallyBased
    frame.firstMaterial?.roughness.contents = 0.5
    let frameNode = SCNNode(geometry: frame)
    frameNode.castsShadow = true
    tilt.addChildNode(frameNode)
    let plane = SCNPlane(width: CGFloat(width), height: CGFloat(height))
    plane.cornerRadius = CGFloat(width) * 0.08
    photo = plane.firstMaterial ?? SCNMaterial()
    photo.lightingModel = .lambert
    let photoNode = SCNNode(geometry: plane)
    photoNode.position = SCNVector3(0, 0, 0.041)
    tilt.addChildNode(photoNode)
    shellMaterial.lightingModel = .lambert
    shellMaterial.isDoubleSided = false
    shell.position = SCNVector3(0, 0, 0.044)
    shell.scale = SCNVector3(1.24, 1.24, 1)
    shell.castsShadow = true
    tilt.addChildNode(shell)
  }

  func setDimmed(_ dimmed: Bool) {
    let tint = UIColor(white: dimmed ? 0.9 : 1, alpha: 1)
    photo.multiply.contents = tint
    shellMaterial.multiply.contents = tint
  }

  func show(image: CGImage, heights: [Float]?) {
    guard image !== lastImage else { return }
    lastImage = image
    photo.diffuse.contents = image
    shellMaterial.diffuse.contents = image
    shellMaterial.emission.contents = image
    shellMaterial.emission.intensity = 0.12
    guard let heights else { shell.geometry = nil; return }
    shell.geometry = Self.relief(heights, width: w, height: h, material: shellMaterial)
  }

  /// A grid lifted by the height map. Only the raised part is kept, so it reads as the subject
  /// leaning out of the window.
  private static func relief(_ heights: [Float], width: Float, height: Float, material: SCNMaterial) -> SCNGeometry? {
    let gw = WindowHeightMaps.columns, gh = WindowHeightMaps.rows
    let depth = width * 0.55
    var positions: [SCNVector3] = [], normals: [SCNVector3] = [], uvs: [CGPoint] = []
    positions.reserveCapacity(gw * gh)
    func value(_ i: Int, _ j: Int) -> Float { heights[min(gh - 1, max(0, j)) * gw + min(gw - 1, max(0, i))] }
    let dx = width / Float(gw - 1), dy = height / Float(gh - 1)
    for j in 0..<gh {
      for i in 0..<gw {
        positions.append(SCNVector3((Float(i) / Float(gw - 1) - 0.5) * width, (0.5 - Float(j) / Float(gh - 1)) * height,
          value(i, j) * depth))
        let sx = (value(i + 1, j) - value(i - 1, j)) * depth / (2 * dx)
        let sy = (value(i, j - 1) - value(i, j + 1)) * depth / (2 * dy)
        let length = sqrt(sx * sx + sy * sy + 1)
        normals.append(SCNVector3(-sx / length, -sy / length, 1 / length))
        uvs.append(CGPoint(x: CGFloat(i) / CGFloat(gw - 1), y: CGFloat(j) / CGFloat(gh - 1)))
      }
    }
    var indices: [UInt32] = []
    for j in 0..<(gh - 1) {
      for i in 0..<(gw - 1) {
        let a = UInt32(j * gw + i), b = a + 1, c = a + UInt32(gw), d = c + 1
        let raised = [value(i, j), value(i + 1, j), value(i, j + 1), value(i + 1, j + 1)].min() ?? 0
        guard raised > 0.05 else { continue }
        indices += [a, c, b, b, c, d]
      }
    }
    guard !indices.isEmpty else { return nil }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
      SCNGeometrySource(textureCoordinates: uvs)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geometry.firstMaterial = material
    return geometry
  }
}
