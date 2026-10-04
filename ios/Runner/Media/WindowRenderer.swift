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
    // Each subject is measured against its own nearest point (the highest depth within
    // about a third of the frame), so two people, or a cup and a hand, both stand out
    // instead of only the closest one.
    let reach = gw / 3
    var nearest = grid
    for j in 0..<gh {   // separable max filter: rows, then columns
      for i in 0..<gw {
        var m: Float = 0
        for k in max(0, i - reach)...min(gw - 1, i + reach) { m = max(m, grid[j * gw + k]) }
        nearest[j * gw + i] = m
      }
    }
    var local = nearest
    for j in 0..<gh {
      for i in 0..<gw {
        var m: Float = 0
        for k in max(0, j - reach)...min(gh - 1, j + reach) { m = max(m, nearest[k * gw + i]) }
        local[j * gw + i] = m
      }
    }
    for j in 0..<gh {
      for i in 0..<gw {
        let u = Float(i) / Float(gw - 1), v = Float(j) / Float(gh - 1)
        let border = ramp(u / 0.2) * ramp((1 - u) / 0.2) * ramp(v / 0.16) * ramp((1 - v) / 0.2)
        let top = max(cut + 0.08, local[j * gw + i])
        let rise = min(1, max(0, (grid[j * gw + i] - cut) / max(1e-3, top - cut)))
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
///
/// The edit is planned once per song from its sections and seed, so no two songs are cut
/// the same way: an introduction of each sound, then scenes chosen by the energy of each bar
/// (quiet bars get slow, wide scenes; loud bars get close, fast ones, often two per bar),
/// a burst at the first loud bar, and a pull-back at the end.
final class WindowFrameRenderer {
  private enum Kind { case intro, wall, floor, follow, pair, clones, orbit, tunnel, carousel, drop, outro }
  private struct Planned { let kind: Kind; let from: Int; let to: Int }

  private let width: Int, height: Int
  private let renderer: SCNRenderer
  private let scene = SCNScene()
  private let camera = SCNNode()
  private let sun = SCNNode()
  private let backdrop: SCNNode
  private let images: CIContext
  /// what went wrong in the last frame, for tests and logs
  private(set) var lastProblem: String?
  let formats: String
  private let heights: WindowHeightMaps
  private var cards: [String: WindowCard] = [:]
  private var plan: [Planned] = []
  private var firstHit: [String: Int] = [:]
  private var focus: String?
  private var focusFrame = 0
  private var shotIndex = -1
  private var shotFrame = 0
  private var clones: [WindowCard] = []
  private var captured: [(image: CGImage, heights: [Float]?)] = []
  private var lastCaptureAge = Int.max
  private let confetti = SCNNode()
  private var pieces: [(node: SCNNode, direction: SIMD3<Float>, speed: Float, spin: Float)] = []

  private static let beatSamples = 22_500   // 128 BPM at 48 kHz
  private static let barSamples = beatSamples * 4
  private static let grounds: [UIColor] = [
    UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1), UIColor(red: 0.99, green: 0.89, blue: 0.88, alpha: 1),
    UIColor(red: 0.92, green: 0.90, blue: 0.99, alpha: 1), UIColor(red: 0.89, green: 0.96, blue: 0.93, alpha: 1),
    UIColor(red: 0.99, green: 0.94, blue: 0.86, alpha: 1), UIColor(red: 0.89, green: 0.93, blue: 0.99, alpha: 1),
  ]
  private static let paper: [UIColor] = [
    UIColor(red: 0.94, green: 0.44, blue: 0.42, alpha: 1), UIColor(red: 0.61, green: 0.52, blue: 0.94, alpha: 1),
    UIColor(red: 0.95, green: 0.66, blue: 0.23, alpha: 1), UIColor(red: 0.31, green: 0.68, blue: 0.55, alpha: 1),
    UIColor(red: 0.31, green: 0.59, blue: 0.88, alpha: 1), UIColor(red: 0.88, green: 0.44, blue: 0.71, alpha: 1),
  ]

  init?(width: Int, height: Int, ground: CGColor) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    self.width = width
    self.height = height
    renderer = SCNRenderer(device: device, options: nil)
    formats = "snapshot"
    images = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
    heights = WindowHeightMaps(model: DepthModelStore.shared.loadedModel())

    scene.background.contents = UIColor(cgColor: ground)
    let lens = SCNCamera()
    lens.fieldOfView = 30
    lens.zNear = 0.1
    lens.zFar = 200
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
    light.orthographicScale = 8
    sun.light = light
    scene.rootNode.addChildNode(sun)
    let fill = SCNNode()
    fill.light = SCNLight()
    fill.light?.type = .ambient
    fill.light?.intensity = 520
    scene.rootNode.addChildNode(fill)

    let wall = SCNPlane(width: 400, height: 400)
    wall.firstMaterial?.diffuse.contents = UIColor(cgColor: ground)
    wall.firstMaterial?.lightingModel = .constant   // the ground keeps its exact colour
    backdrop = SCNNode(geometry: wall)
    backdrop.position = SCNVector3(0, 0, -40)
    scene.rootNode.addChildNode(backdrop)

    var dice = Dice(seed: 7)
    for index in 0..<80 {
      let piece = SCNBox(width: 0.08, height: 0.08, length: 0.012, chamferRadius: 0.012)
      piece.firstMaterial?.diffuse.contents = index % 7 == 0 ? UIColor.white : Self.paper[index % Self.paper.count]
      piece.firstMaterial?.lightingModel = .lambert
      let node = SCNNode(geometry: piece)
      let a = Float(dice.unit()) * 2 * Float.pi, lift = 0.3 + Float(dice.unit()) * 0.7
      pieces.append((node, SIMD3(cos(a) * (1 - lift * 0.5), lift, sin(a) * (1 - lift * 0.5)),
        3 + Float(dice.unit()) * 5, (Float(dice.unit()) - 0.5) * 16))
      confetti.addChildNode(node)
    }
    confetti.isHidden = true
    scene.rootNode.addChildNode(confetti)
  }

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

  // MARK: planning

  private func makePlan(_ arrangement: ArrangementPayload?, count: Int) {
    let total = arrangement?.totalSamples ?? Self.barSamples * 8
    let bars = max(1, total / Self.barSamples)
    let sections = arrangement?.sections ?? []
    func energy(_ bar: Int) -> String {
      sections.first { $0.fromBar <= bar && bar < $0.toBar }?.energy ?? (bar < bars / 4 ? "calm" : "mid")
    }
    let drop = sections.first { $0.energy == "high" }?.fromBar
    var dice = Dice(seed: UInt64(bitPattern: Int64(arrangement?.seed ?? 1)))
    var plan: [Planned] = []
    var last: Kind?
    func add(_ kind: Kind, _ from: Int, _ to: Int) { plan.append(Planned(kind: kind, from: from, to: to)); last = kind }
    let introBars = count >= 4 && bars >= 8 ? 2 : 1
    add(.intro, 0, introBars * Self.barSamples)
    var bar = introBars
    while bar < bars {
      let from = bar * Self.barSamples, to = from + Self.barSamples
      if bars > 2 && bar == bars - 1 { add(.outro, from, to); break }
      if let drop, bar == drop, drop > 0 { add(.drop, from, to); bar += 1; continue }
      let level = energy(bar)
      var pool: [Kind]
      switch level {
      case "calm": pool = [.floor, .orbit, .carousel, .tunnel, .wall]
      case "high": pool = [.follow, .pair, .clones, .orbit, .carousel, .follow, .tunnel]
      default: pool = [.follow, .pair, .carousel, .floor, .tunnel, .clones, .orbit]
      }
      if count < 2 { pool = pool.filter { ![.pair, .carousel, .tunnel].contains($0) } }
      if count < 3 { pool = pool.filter { $0 != .carousel } }
      if pool.isEmpty { pool = [.follow] }
      func pick() -> Kind {
        var choice = pool[dice.next(pool.count)]
        for _ in 0..<6 where choice == last { choice = pool[dice.next(pool.count)] }
        return choice
      }
      let first = pick()
      if level == "high" && [.follow, .pair, .clones].contains(first) && dice.next(3) > 0 {
        // loud bars often cut twice
        add(first, from, from + Self.barSamples / 2)
        add(pick(), from + Self.barSamples / 2, to)
      } else {
        add(first, from, to)
      }
      bar += 1
    }
    self.plan = plan
  }

  // MARK: drawing

  func draw(frame: Int, arrangement: ArrangementPayload? = nil,
    cards keyed: [(key: String, image: CGImage?, frameKey: String, playing: Bool, age: Int, punch: CGFloat)],
    into buffer: CVPixelBuffer) throws {
    let t = Float(frame) / 30
    let sample = frame * 1600
    let count = max(1, keyed.count)
    if plan.isEmpty {
      makePlan(arrangement, count: count)
      for event in arrangement?.videoEvents ?? [] where (firstHit[event.assetId] ?? .max) > event.destinationStartSample {
        firstHit[event.assetId] = event.destinationStartSample
      }
    }
    let layout = Self.layout(count: count, aspect: CGFloat(width) / CGFloat(height))
    let cardW = Float(layout.cards.first?.width ?? 1.2), cardH = Float(layout.cards.first?.height ?? 1.6)
    let tanHalf = tan(15 * Float.pi / 180), aspect = Float(width) / Float(height)
    let close = cardH * 1.75 / (2 * tanHalf)

    // which scene is on
    let index = plan.lastIndex { $0.from <= sample } ?? 0
    let shot = plan[index]
    if index != shotIndex {
      shotIndex = index
      shotFrame = frame
      captured.removeAll()
      lastCaptureAge = .max
      focus = nil
    }
    let u = Float(sample - shot.from) / Float(max(1, shot.to - shot.from))
    let sinceShot = Float(frame - shotFrame) / 30

    // cards, textures, and who is sounding
    let live = Set(keyed.map(\.key))
    for (key, card) in cards where !live.contains(key) { card.root.removeFromParentNode(); cards.removeValue(forKey: key) }
    var nodes: [WindowCard] = []
    for item in keyed {
      let card = cards[item.key] ?? {
        let made = WindowCard(width: cardW, height: cardH)
        scene.rootNode.addChildNode(made.root)
        cards[item.key] = made
        return made
      }()
      if let image = item.image { card.show(image: image, heights: heights.heights(for: image, key: item.frameKey)) }
      nodes.append(card)
    }
    let lead = keyed.indices.filter { keyed[$0].playing }.min { keyed[$0].age < keyed[$1].age }
    // follow: cut to whoever just started, but hold each cut at least 0.3 s
    if let lead, focus != keyed[lead].key, focus == nil || frame - focusFrame >= 9 {
      if focus == nil || [.follow, .intro].contains(shot.kind) {
        focus = keyed[lead].key
        focusFrame = frame
      }
    }
    if focus == nil || !live.contains(focus ?? "") { focus = keyed.first?.key; focusFrame = frame }
    let focusIndex = keyed.firstIndex { $0.key == focus } ?? 0
    let sinceFocus = Float(frame - focusFrame) / 30

    // defaults: everyone on the wall, facing the camera
    var ground = Self.grounds[(sample / (Self.barSamples * 2)) % Self.grounds.count]
    var flash: Float = 0
    var sway: Float = 1
    confetti.isHidden = true
    for (i, card) in nodes.enumerated() {
      let rect = layout.cards[min(i, layout.cards.count - 1)]
      card.root.isHidden = false
      card.root.position = SCNVector3(Float(rect.midX), Float(rect.midY), 0)
      card.root.eulerAngles = SCNVector3(0, 0, 0)
    }
    for clone in clones { clone.root.isHidden = true }
    func solo(_ i: Int) {
      for (j, card) in nodes.enumerated() { card.root.isHidden = j != i }
      nodes[i].root.position = SCNVector3(0, 0, 0)
      ground = Self.grounds[1 + i % (Self.grounds.count - 1)]
    }
    func aim(_ position: SCNVector3, _ target: SCNVector3) {
      camera.position = position
      camera.look(at: target)
    }

    switch shot.kind {
    case .intro:
      // each sound arrives on its own colour, at its first hit
      let arrived = keyed.indices.filter { (firstHit[keyed[$0].key] ?? 0) <= sample }
      let who = arrived.max { (firstHit[keyed[$0].key] ?? 0) < (firstHit[keyed[$1].key] ?? 0) } ?? 0
      solo(who)
      let since = Float(sample - (firstHit[keyed[who].key] ?? shot.from)) / 48_000
      let side: Float = who % 2 == 0 ? -1 : 1
      aim(SCNVector3(side * 0.45, 0.1, close * 0.95 - min(1, since) * 0.25), SCNVector3(0, -0.05, 0))
    case .follow:
      solo(focusIndex)
      let side: Float = focusIndex % 2 == 0 ? -1 : 1
      aim(SCNVector3(side * (0.35 + sinceFocus * 0.12), 0.12, close + 0.2 - sinceFocus * 0.15), SCNVector3(0, -0.05, 0))
    case .pair:
      // the two most recent sounds, side by side
      let order = keyed.indices.sorted { keyed[$0].age < keyed[$1].age }
      let a = order.first ?? 0, b = order.dropFirst().first ?? (a + 1) % nodes.count
      for (j, card) in nodes.enumerated() { card.root.isHidden = j != a && j != b }
      let gap = cardW / 2 + 0.22
      nodes[min(a, b)].root.position = SCNVector3(-gap, 0, 0)
      nodes[max(a, b)].root.position = SCNVector3(gap, 0, 0)
      nodes[min(a, b)].root.eulerAngles = SCNVector3(0, 0.22, 0)
      nodes[max(a, b)].root.eulerAngles = SCNVector3(0, -0.22, 0)
      let fit = (cardW * 2 + 0.9) / (2 * tanHalf * aspect)
      aim(SCNVector3(sin(t * 0.6) * 0.4, 0.2, fit - u * 0.4), SCNVector3(0, 0, 0))
      ground = Self.grounds[(shotIndex % 5) + 1]
    case .clones:
      // every new hit of the lead leaves a still beside it
      solo(focusIndex)
      let hero = nodes[focusIndex]
      hero.root.position = SCNVector3(-0.85, 0, 0)
      let item = keyed[focusIndex]
      if item.playing, item.age < lastCaptureAge, let image = item.image, captured.count < 4 {
        captured.append((image, heights.heights(for: image, key: item.frameKey)))
      }
      lastCaptureAge = item.playing ? item.age : .max
      while clones.count < captured.count {
        let made = WindowCard(width: cardW, height: cardH)
        scene.rootNode.addChildNode(made.root)
        clones.append(made)
      }
      for (j, still) in captured.enumerated() {
        let clone = clones[j]
        clone.root.isHidden = false
        clone.show(image: still.image, heights: still.heights)
        clone.root.position = SCNVector3(-0.85 + Float(j + 1) * cardW * 0.42, 0, -Float(j + 1) * 0.75)
        clone.root.eulerAngles = SCNVector3(0, 0, 0)
        clone.tilt.position = SCNVector3(0, 0, 0)
        clone.tilt.eulerAngles = SCNVector3(0, -0.1, 0)
        clone.tilt.scale = SCNVector3(1, 1, 1)
      }
      let fit = (cardW * 2.6) / (2 * tanHalf * aspect)
      aim(SCNVector3(0.2 - u * 0.3, 0.25, fit), SCNVector3(0.15, -0.1, -1))
    case .orbit:
      // circle one card to show how far it stands out
      solo(focusIndex)
      sway = 0
      let angle = -1.05 + u * 2.1
      aim(SCNVector3(sin(angle) * close * 0.95, 0.15, cos(angle) * close * 0.95), SCNVector3(0, 0, 0.15))
    case .floor:
      // everyone standing on a floor, seen from above
      let columns = count <= 2 ? count : count <= 4 ? 2 : 3
      for (i, card) in nodes.enumerated() {
        let col = i % columns, row = i / columns
        card.root.position = SCNVector3((Float(col) - Float(columns - 1) / 2) * (cardW + 0.55), 0, -Float(row) * (cardH * 1.15))
      }
      let rows = Float((count + columns - 1) / columns)
      let depthMid = -(rows - 1) * cardH * 0.57
      let fit = (Float(columns) * (cardW + 0.55) + 0.6) / (2 * tanHalf * aspect)
      let around = sin(t * 0.5) * 0.35
      aim(SCNVector3(sin(around) * fit, fit * 0.62, depthMid + cos(around) * fit * 0.85 - u * 0.6), SCNVector3(0, 0, depthMid))
    case .tunnel:
      // walk down a corridor of windows
      sway = 0
      for (i, card) in nodes.enumerated() {
        let side: Float = i % 2 == 0 ? -1 : 1
        card.root.position = SCNVector3(side * (cardW * 0.62), 0, -Float(i) * 2.2)
        card.root.eulerAngles = SCNVector3(0, -side * 0.55, 0)
      }
      let length = Float(nodes.count - 1) * 2.2
      let z = 4.5 - u * (length + 1.5)
      aim(SCNVector3(sin(t * 0.8) * 0.15, 0.1, z), SCNVector3(0, 0, z - 6))
    case .carousel:
      sway = 0
      let radius = max(1.3, Float(count) * (cardW + 0.4) / (2 * Float.pi))
      for (i, card) in nodes.enumerated() {
        let angle = Float(i) / Float(count) * 2 * Float.pi - t * 0.55
        card.root.position = SCNVector3(sin(angle) * radius, -0.2, cos(angle) * radius)
        card.root.eulerAngles = SCNVector3(0, angle, 0)
      }
      let fit = (radius * 2 + cardW * 1.25) / (2 * tanHalf * aspect) * 1.02
      aim(SCNVector3(0, -0.2 + fit * sin(0.3), fit * cos(0.3)), SCNVector3(0, -0.2, 0))
    case .drop:
      // a white flash, everyone bursts into view, confetti
      flash = max(0, 1 - sinceShot * 5)
      let rect = layout.cards[min(focusIndex, layout.cards.count - 1)]
      let pull = 1 - pow(1 - min(1, sinceShot / 0.9), 3)
      let from = SCNVector3(Float(rect.midX), Float(rect.midY), 0)
      aim(SCNVector3(from.x * (1 - pull), from.y * (1 - pull) + 0.2 * pull, close * 0.7 + (layout.distance - close * 0.7) * pull),
        SCNVector3(from.x * (1 - pull), from.y * (1 - pull), 0))
      confetti.isHidden = sinceShot > 2.4
      for piece in pieces {
        let s = sinceShot
        let reach = (1 - exp(-s * 2.2)) / 2.2 * piece.speed
        piece.node.position = SCNVector3(piece.direction.x * reach, piece.direction.y * reach - 2.2 * s * s, 0.6 + piece.direction.z * reach)
        piece.node.eulerAngles = SCNVector3(s * piece.spin, s * piece.spin * 0.7, 0)
      }
    case .outro:
      let pull = u * u * (3 - 2 * u)
      aim(SCNVector3(sin(t * 0.3) * 0.3, 0.1, layout.distance * (0.9 + pull * 0.25)), SCNVector3(0, 0, 0))
    case .wall:
      let turn = sin(t * 0.6) * 0.9
      aim(SCNVector3(turn, 0.15 + sin(t * 0.23) * 0.2, layout.distance * (1.02 - u * 0.1)), SCNVector3(0, 0, 0))
    }

    // shared motion: a push on every beat and on every cut, hops and sway for sounding cards
    let intoBeat = Float(sample % Self.beatSamples) / 48_000
    let cutPunch = exp(-min(sinceShot, shot.kind == .follow ? sinceFocus : sinceShot) * 7)
    camera.camera?.fieldOfView = CGFloat(30 - exp(-intoBeat * 9) * 1.1 - cutPunch * 3)
    sun.eulerAngles = SCNVector3(-0.55, sin(t * 0.9) * 0.75, 0)
    scene.background.contents = ground
    backdrop.geometry?.firstMaterial?.diffuse.contents = ground
    for (i, item) in keyed.enumerated() {
      let card = nodes[i]
      let seconds = Float(item.age) / 48_000
      let p = Float(item.punch)
      let swing = item.playing ? sin(t * 2.3 + Float(i)) * 0.42 : sin(t * 0.7 + Float(i)) * 0.1
      card.tilt.eulerAngles = SCNVector3(-0.05, swing * sway, item.playing ? sin(seconds * 9) * 0.03 * p : 0)
      let hop = item.playing ? max(0, sin(min(1, seconds / 0.22) * Float.pi)) : 0
      card.tilt.position = SCNVector3(0, hop * 0.16, p * 0.08)
      card.tilt.scale = SCNVector3(1 + 0.06 * p, 1 - 0.09 * p, 1)
      card.setDimmed(!item.playing)
    }

    // SceneKit draws the frame itself (with 4x multisampling); we only copy it into the video
    let snapshot = renderer.snapshot(atTime: TimeInterval(t), with: CGSize(width: width, height: height),
      antialiasingMode: .multisampling4X)
    guard let picture = snapshot.cgImage else {
      lastProblem = "snapshot had no image"
      throw VideoRenderError.writerFailed
    }
    lastProblem = nil
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    var output = CIImage(cgImage: picture)
    if flash > 0 {
      output = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(flash))).cropped(to: bounds).composited(over: output)
    }
    images.render(output, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
  }
}

/// Seeded choices for the edit.
private struct Dice {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func raw() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func next(_ n: Int) -> Int { Int(raw() % UInt64(max(1, n))) }
  mutating func unit() -> Double { Double(raw() >> 11) / Double(1 << 53) }
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
