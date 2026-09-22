public final class IOSPendingOperationController<Value> {
    private struct PendingOperation {
        let id: UInt64
        let value: Value
    }

    private var nextOperationID: UInt64 = 0
    private var pending: PendingOperation?

    public init() {}

    public func begin(_ value: Value) -> UInt64? {
        guard pending == nil else { return nil }

        nextOperationID &+= 1
        let operationID = nextOperationID
        pending = PendingOperation(id: operationID, value: value)
        return operationID
    }

    public func take(operationID: UInt64) -> Value? {
        guard let current = pending, current.id == operationID else {
            return nil
        }

        pending = nil
        return current.value
    }

    public func takeCurrent() -> Value? {
        guard let current = pending else { return nil }
        pending = nil
        return current.value
    }
}
