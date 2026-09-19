import Foundation

final class ClipRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(date: Date, jpeg: Data)] = []
    private let window: TimeInterval

    init(window: TimeInterval = 16) {
        self.window = window
    }

    func append(_ jpeg: Data) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        frames.append((now, jpeg))
        frames.removeAll { now.timeIntervalSince($0.date) > window }
    }

    func freeze() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return frames.filter { now.timeIntervalSince($0.date) <= window }.map(\.jpeg)
    }
}
