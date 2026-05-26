import Foundation
import Network

internal final class RefetchTriggerController: @unchecked Sendable {
    private final class NetworkReconnectGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isFirstUpdate = true
        private var previouslySatisfied = false

        func shouldFire(nowSatisfied: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            if isFirstUpdate {
                isFirstUpdate = false
                previouslySatisfied = nowSatisfied
                return false
            }

            guard nowSatisfied, !previouslySatisfied else {
                previouslySatisfied = nowSatisfied
                return false
            }

            previouslySatisfied = true
            return true
        }
    }

    private let sceneActiveNotificationName: Notification.Name
    private var sceneActiveObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorQueue: DispatchQueue?

    var isSceneActiveArmed: Bool {
        sceneActiveObserver != nil
    }

    var isNetworkReconnectArmed: Bool {
        pathMonitor != nil
    }

    init(sceneActiveNotificationName: Notification.Name) {
        self.sceneActiveNotificationName = sceneActiveNotificationName
    }

    @MainActor
    func startSceneActive(_ action: @escaping @MainActor @Sendable () async -> Void) {
        guard sceneActiveObserver == nil else { return }

        sceneActiveObserver = NotificationCenter.default.addObserver(
            forName: sceneActiveNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await action()
            }
        }
    }

    func stopSceneActive() {
        if let observer = sceneActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            sceneActiveObserver = nil
        }
    }

    @MainActor
    func startNetworkReconnect(_ action: @escaping @MainActor @Sendable () async -> Void) {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "sunkit.refetch-trigger.network-monitor", qos: .utility)
        let gate = NetworkReconnectGate()

        monitor.pathUpdateHandler = { path in
            guard gate.shouldFire(nowSatisfied: path.status == .satisfied) else {
                return
            }

            Task { @MainActor in
                await action()
            }
        }

        monitor.start(queue: queue)
        pathMonitor = monitor
        pathMonitorQueue = queue
    }

    func stopNetworkReconnect() {
        pathMonitor?.cancel()
        pathMonitor = nil
        pathMonitorQueue = nil
    }

    func stop() {
        stopSceneActive()
        stopNetworkReconnect()
    }

    deinit {
        stop()
    }
}
