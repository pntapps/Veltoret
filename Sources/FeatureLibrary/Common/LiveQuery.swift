import SwiftUI
import VeltoretKit
import VeltoretUI

/// Port of Windows `LivePage`: runs `load` off the main thread and re-runs it (throttled 250 ms, never concurrently)
/// when `AppServices.db.changed` names one of `tables`, when connectivity changes and, with `watchScan`, publishes the
/// scanner state. Pages stay mounted in the back stack, so when a `route` is given the query only refreshes while
/// that route is on screen; changes made meanwhile are applied as soon as it is shown again.
///
/// ```swift
/// @StateObject private var live = LiveQuery(tables: ["movies", "watch_state"], route: .movies()) { try Model.load() }
/// var body: some View { … live.value … }.task { live.start() }
/// ```
@MainActor
public final class LiveQuery<Value>: ObservableObject {
    /// The latest result (nil until the first load finishes).
    @Published public private(set) var value: Value?
    /// The latest scanner state (only updated with `watchScan`).
    @Published public private(set) var scan = ScanState()
    /// The error thrown by the latest load, if any (the previous `value` is kept).
    @Published public private(set) var error: Error?

    public let tables: Set<String>
    private let route: Route?
    private let load: @Sendable () async throws -> Value
    private let bag = SubscriptionBag()
    private var dirty = true
    private var running = false
    private var again = false
    private var throttle: Task<Void, Never>?
    private var started = false

    /// Called on the main actor after each new scan state (with `watchScan`).
    public var onScan: ((ScanState) -> Void)?

    public init(tables: [String], route: Route? = nil, watchOnline: Bool = true, watchScan: Bool = false,
                load: @escaping @Sendable () async throws -> Value) {
        let set = Set(tables)
        self.tables = set
        self.route = route
        self.load = load
        if let db = AppServices.db {
            db.changed.subscribe { [weak self] changed in
                guard !changed.isDisjoint(with: set) else { return }
                Task { @MainActor in self?.invalidate() }
            }.store(in: bag)
        }
        if watchOnline, let connectivity = AppServices.connectivity {
            connectivity.onlineChanged.subscribe { [weak self] _ in
                Task { @MainActor in self?.invalidate() }
            }.store(in: bag)
        }
        if watchScan, let scanner = AppServices.scanner {
            scan = scanner.state
            scanner.stateChanged.subscribe { [weak self] s in
                Task { @MainActor in
                    guard let self else { return }
                    self.scan = s
                    self.onScan?(s)
                }
            }.store(in: bag)
        }
        if route != nil {
            Navigator.shared.navigated.subscribe { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.dirty, self.isActive else { return }
                    self.schedule()
                }
            }.store(in: bag)
        }
    }

    deinit { bag.cancelAll() }

    /// Starts the first load (idempotent; call from `.task` / `.onAppear`).
    public func start() {
        if started { if dirty { schedule() }; return }
        started = true
        Task { await refresh() }
    }

    /// Marks the data stale and re-queries soon (when the page is on screen).
    public func invalidate() {
        dirty = true
        guard started, isActive else { return }
        schedule()
    }

    /// Re-queries now (awaits the result). A call while one runs queues exactly one more run.
    public func refresh() async {
        if running { again = true; return }
        running = true
        dirty = false
        let load = self.load
        do {
            let result = try await Task.detached(priority: .userInitiated) { try await load() }.value
            value = result
            error = nil
        } catch {
            Log.error("LiveQuery load failed: \(error)")
            self.error = error
            if value == nil { dirty = true }
        }
        running = false
        if again { again = false; invalidate() }
    }

    private var isActive: Bool {
        guard let route else { return true }
        return Navigator.shared.current?.route == route
    }

    private func schedule() {
        if throttle != nil { return }
        throttle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.throttle = nil
            await self.refresh()
        }
    }
}
