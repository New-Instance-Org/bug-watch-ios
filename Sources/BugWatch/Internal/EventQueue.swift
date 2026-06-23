import Foundation

/// Bounded in-memory FIFO queue for pending events. Thread-safe. This is the
/// skeleton's holding area; real persistence + delivery arrive in a later
/// milestone.
final class EventQueue {
    private let maxSize: Int
    private let lock = NSLock()
    private var items: [BugWatchEvent] = []

    init(maxSize: Int) {
        self.maxSize = max(1, maxSize)
    }

    /// Appends an event, dropping the oldest if at capacity. Returns `false`
    /// if an event had to be dropped to make room.
    @discardableResult
    func enqueue(_ event: BugWatchEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var droppedOne = false
        if items.count >= maxSize {
            items.removeFirst()
            droppedOne = true
        }
        items.append(event)
        return !droppedOne
    }

    /// Removes and returns up to `count` events from the front.
    func dequeue(upTo count: Int) -> [BugWatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        let n = min(max(count, 0), items.count)
        let batch = Array(items.prefix(n))
        items.removeFirst(n)
        return batch
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}
