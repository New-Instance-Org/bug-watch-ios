import Foundation
import Network
import Combine

/// System-network availability tracker. Wraps `NWPathMonitor` and exposes
/// an `@Published isOnline` so SDK code (subscription clients in
/// particular) can pause reconnect loops while there's no usable network.
///
/// Mirrors Android's `NetworkMonitor` semantics: `isOnline` only flips
/// true when the path is satisfied AND not expensive-only / unsatisfied.
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cloud.newinstance.liveandaichat.network", qos: .utility)
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
