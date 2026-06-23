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

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cloud.newinstance.bugwatch.network", qos: .utility)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
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
