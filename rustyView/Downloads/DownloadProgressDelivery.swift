import Foundation

/// Coalesce on the delegate side, before creating MainActor work. Keep the last
/// sample so a quiet connection still gets a trailing update. Transfer UUIDs
/// prevent a retry or a different URLSession's task number sharing this state.
final class DownloadProgressDelivery: @unchecked Sendable {
    struct Sample {
        let envelope: DownloadTaskEnvelope
        let received: Int64
        let expected: Int64?
    }
    private struct Pending {
        var sample: Sample
        var deliver: (Sample) -> Void
        var lastSent: TimeInterval
        var timer: DispatchWorkItem?
        var timerID: UUID?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "downloads.progress", qos: .utility)
    private let interval: TimeInterval
    private var pending: [UUID: Pending] = [:]
    private var enabled = true

    init(interval: TimeInterval = 0.25) { self.interval = interval }

    func submit(_ sample: Sample, deliver: @escaping (Sample) -> Void) {
        lock.lock()
        let id = sample.envelope.transferID
        let now = ProcessInfo.processInfo.systemUptime
        var state = pending[id] ?? Pending(sample: sample, deliver: deliver, lastSent: -.infinity)
        state.sample = sample
        state.deliver = deliver
        let sendNow = enabled && now - state.lastSent >= interval
        if sendNow {
            state.timer?.cancel()
            state.timer = nil
            state.timerID = nil
            state.lastSent = now
        } else if enabled && state.timer == nil {
            let token = UUID()
            let timer = DispatchWorkItem { [weak self] in self?.flush(id, timerID: token) }
            state.timer = timer
            state.timerID = token
            queue.asyncAfter(deadline: .now() + max(0, interval - (now - state.lastSent)), execute: timer)
        }
        pending[id] = state
        if sendNow { queue.async { deliver(sample) } }
        lock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        guard self.enabled != enabled else { lock.unlock(); return }
        self.enabled = enabled
        let ids = Array(pending.keys)
        for id in ids {
            pending[id]?.timer?.cancel()
            pending[id]?.timer = nil
            pending[id]?.timerID = nil
        }
        lock.unlock()
        if enabled { for id in ids { flush(id) } }
    }

    func remove(_ id: UUID) {
        lock.lock()
        pending.removeValue(forKey: id)?.timer?.cancel()
        lock.unlock()
    }

    private func flush(_ id: UUID, timerID: UUID? = nil) {
        lock.lock()
        guard enabled, var state = pending[id], timerID == nil || state.timerID == timerID else { lock.unlock(); return }
        state.timer = nil
        state.timerID = nil
        state.lastSent = ProcessInfo.processInfo.systemUptime
        pending[id] = state
        let delivery = state.deliver
        let sample = state.sample
        queue.async { delivery(sample) }
        lock.unlock()
    }

    deinit { for state in pending.values { state.timer?.cancel() } }
}
