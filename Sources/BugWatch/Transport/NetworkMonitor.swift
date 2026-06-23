import Foundation
import Network
import Combine

/// System-network availability tracker. Wraps `NWPathMonitor` and exposes
/// an `@Published isOnline` so the delivery pipeline can pause retry loops
/// while there's no usable network.
///
/// `isOnline` only flips true when the path is satisfied.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    /// Invoked (on the main queue) whenever connectivity flips to online. The
    /// delivery pipeline uses this to resume draining as soon as the network
    /// comes back.
    var onBecameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cloud.newinstance.bugwatch.network", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if online && !wasOnline {
                    self.onBecameOnline?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    deinit {
        if started { monitor.cancel() }
    }
}
