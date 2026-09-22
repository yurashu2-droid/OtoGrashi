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

  func start(operationId: String) throws -> CancellationToken {
    guard !operationId.isEmpty else { throw AudioRenderError.unsupportedContract }
    guard operations[operationId] == nil else {
      throw AudioRenderError.duplicateOperationId
    }
    let token = CancellationToken(operationId: operationId)
    operations[operationId] = token
    return token
  }

  func cancel(operationId: String) {
    operations[operationId]?.cancel()
  }

  func finish(operationId: String) {
    operations.removeValue(forKey: operationId)
  }
}
