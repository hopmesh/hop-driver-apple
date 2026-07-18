import Foundation

struct CompactionDeadline {
    private(set) var firstDirty: TimeInterval?

    mutating func nextDelay(now: TimeInterval, debounce: TimeInterval,
                            maximumDelay: TimeInterval) -> TimeInterval {
        let first = firstDirty ?? now
        firstDirty = first
        return min(debounce, max(0, maximumDelay - (now - first)))
    }

    mutating func clear() { firstDirty = nil }
}

/// One bounded serial writer. Pending work is last-write-wins per mirror key.
final class CoalescingWriter {
    private let queue = DispatchQueue(label: "hop.mirror.writer", qos: .utility)
    private let lock = NSLock()
    private let maximumKeys: Int
    private var pending: [String: () -> Void] = [:]
    private var keyOrder: [String] = []
    private var draining = false

    init(maximumKeys: Int = 4) { self.maximumKeys = maximumKeys }

    func submit(key: String, action: @escaping () -> Void) {
        lock.lock()
        precondition(pending[key] != nil || pending.count < maximumKeys, "mirror writer key limit exceeded")
        if pending[key] == nil { keyOrder.append(key) }
        pending[key] = action
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    func runNow<T>(key: String, action: () -> T) -> T {
        lock.lock()
        pending.removeValue(forKey: key)
        keyOrder.removeAll { $0 == key }
        lock.unlock()
        return queue.sync(execute: action)
    }

    func flush() { queue.sync {} }

    private func drain() {
        while true {
            lock.lock()
            guard let key = keyOrder.first else {
                draining = false
                lock.unlock()
                return
            }
            keyOrder.removeFirst()
            let action = pending.removeValue(forKey: key)
            lock.unlock()
            action?()
        }
    }
}
