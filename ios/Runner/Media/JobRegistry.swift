import Foundation

final class CancellationToken: @unchecked Sendable {
  let operationId: String
  private let lock = NSLock()
  private var cancelled = false

  init(operationId: String) {
    self.operationId = operationId
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

actor JobRegistry {
  private var operations: [String: CancellationToken] = [:]
  private var exportOperationId: String?
  private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var cancelledBeforeStart: Set<String> = []

  func start(operationId: String) throws -> CancellationToken {
    guard !operationId.isEmpty else { throw AudioRenderError.unsupportedContract }
    if cancelledBeforeStart.remove(operationId) != nil {
      throw AudioRenderError.cancelled
    }
    guard operations[operationId] == nil else {
      throw AudioRenderError.duplicateOperationId
    }
    let token = CancellationToken(operationId: operationId)
    operations[operationId] = token
    return token
  }

  func startExclusiveExport(operationId: String) throws -> CancellationToken {
    if cancelledBeforeStart.remove(operationId) != nil {
      throw AudioRenderError.cancelled
    }
    guard exportOperationId == nil else { throw AudioRenderError.duplicateOperationId }
    let token = try start(operationId: operationId)
    exportOperationId = operationId
    return token
  }

  func cancel(operationId: String) {
    operations[operationId]?.cancel()
  }

  func cancelAndWait(operationId: String) async {
    guard let token = operations[operationId] else {
      cancelledBeforeStart.insert(operationId)
      return
    }
    token.cancel()
    await withCheckedContinuation { continuation in
      finishWaiters[operationId, default: []].append(continuation)
    }
  }

  func finish(operationId: String) {
    operations.removeValue(forKey: operationId)
    if exportOperationId == operationId { exportOperationId = nil }
    let waiters = finishWaiters.removeValue(forKey: operationId) ?? []
    waiters.forEach { $0.resume() }
  }

  func finishForPublication(operationId: String) -> Bool {
    guard let token = operations[operationId], !token.isCancelled else {
      finish(operationId: operationId)
      return false
    }
    finish(operationId: operationId)
    return true
  }
}
