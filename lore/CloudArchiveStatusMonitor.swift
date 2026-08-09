import CloudKit
import Combine
import CoreData
import Foundation

enum CloudArchiveAccountState: Equatable, Sendable {
    case checking
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

enum CloudArchiveOperation: Equatable, Sendable {
    case setup
    case `import`
    case export
}

enum CloudArchiveFailure: Equatable, Sendable {
    case networkUnavailable
    case quotaExceeded
    case notAuthenticated
    case temporarilyUnavailable
    case serverRejected
    case unknown

    static func classify(_ error: Error?) -> Self {
        guard let error else { return .unknown }
        return classify(error as NSError, visited: [])
    }

    private static func classify(_ error: NSError, visited: Set<ObjectIdentifier>) -> Self {
        let identifier = ObjectIdentifier(error)
        guard !visited.contains(identifier) else { return .unknown }
        var visited = visited
        visited.insert(identifier)

        if error.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: error.code) {
            switch code {
            case .networkFailure, .networkUnavailable:
                return .networkUnavailable
            case .quotaExceeded:
                return .quotaExceeded
            case .notAuthenticated:
                return .notAuthenticated
            case .accountTemporarilyUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy:
                return .temporarilyUnavailable
            case .badContainer, .constraintViolation, .incompatibleVersion, .permissionFailure:
                return .serverRejected
            default:
                break
            }
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let classified = classify(underlyingError, visited: visited)
            if classified != .unknown {
                return classified
            }
        }

        return .unknown
    }
}

enum CloudArchiveStatusIssue: Equatable, Sendable {
    case operationFailed(CloudArchiveOperation, CloudArchiveFailure)
}

struct CloudArchiveActiveEvent: Equatable, Sendable {
    let operation: CloudArchiveOperation
    let startedAt: Date
}

enum CloudArchiveDisplayState: Equatable, Sendable {
    case checkingAccount(lastSuccessfulExport: Date?)
    case accountUnavailable(CloudArchiveAccountState, lastSuccessfulExport: Date?)
    case preparing(lastSuccessfulExport: Date?)
    case restoring(lastSuccessfulExport: Date?)
    case syncing(lastSuccessfulExport: Date?)
    case paused(CloudArchiveStatusIssue, lastSuccessfulExport: Date?)
    case readyToSync
    case synced(lastSuccessfulExport: Date)
}

/// A factual snapshot of the CloudKit mirroring state Lore has actually observed.
///
/// `lastSuccessfulExport` changes only after Core Data reports a completed,
/// successful CloudKit export. A local SwiftData save, an available iCloud
/// account, setup, and imports never mark the archive as exported.
struct CloudArchiveStatusSnapshot: Equatable, Sendable {
    var accountState: CloudArchiveAccountState
    var lastSuccessfulExport: Date?
    var lastSuccessfulImport: Date?
    var lastIssue: CloudArchiveStatusIssue?
    fileprivate var activeEvents: [UUID: CloudArchiveActiveEvent]

    init(
        accountState: CloudArchiveAccountState = .checking,
        lastSuccessfulExport: Date? = nil,
        lastSuccessfulImport: Date? = nil,
        lastIssue: CloudArchiveStatusIssue? = nil,
        activeEvents: [UUID: CloudArchiveActiveEvent] = [:]
    ) {
        self.accountState = accountState
        self.lastSuccessfulExport = lastSuccessfulExport
        self.lastSuccessfulImport = lastSuccessfulImport
        self.lastIssue = lastIssue
        self.activeEvents = activeEvents
    }

    /// This is intentionally narrower than “iCloud is available.”
    var hasObservedSuccessfulExport: Bool {
        lastSuccessfulExport != nil
    }

    var activeOperation: CloudArchiveOperation? {
        let operations = activeEvents.values.map(\.operation)
        if operations.contains(.export) { return .export }
        if operations.contains(.import) { return .import }
        if operations.contains(.setup) { return .setup }
        return nil
    }

    var displayState: CloudArchiveDisplayState {
        switch accountState {
        case .noAccount, .restricted, .temporarilyUnavailable, .couldNotDetermine:
            return .accountUnavailable(accountState, lastSuccessfulExport: lastSuccessfulExport)
        case .checking, .available:
            break
        }

        if let activeOperation {
            switch activeOperation {
            case .setup:
                return .preparing(lastSuccessfulExport: lastSuccessfulExport)
            case .import:
                return .restoring(lastSuccessfulExport: lastSuccessfulExport)
            case .export:
                return .syncing(lastSuccessfulExport: lastSuccessfulExport)
            }
        }

        if let lastIssue {
            return .paused(lastIssue, lastSuccessfulExport: lastSuccessfulExport)
        }

        if accountState == .checking {
            return .checkingAccount(lastSuccessfulExport: lastSuccessfulExport)
        }

        if let lastSuccessfulExport {
            return .synced(lastSuccessfulExport: lastSuccessfulExport)
        }

        return .readyToSync
    }
}

struct CloudArchiveObservedEvent: Equatable, Sendable {
    let id: UUID
    let operation: CloudArchiveOperation
    let startedAt: Date
    let endedAt: Date?
    let succeeded: Bool
    let failure: CloudArchiveFailure

    init(
        id: UUID = UUID(),
        operation: CloudArchiveOperation,
        startedAt: Date,
        endedAt: Date? = nil,
        succeeded: Bool = false,
        failure: CloudArchiveFailure = .unknown
    ) {
        self.id = id
        self.operation = operation
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.succeeded = succeeded
        self.failure = failure
    }

    init?(_ event: NSPersistentCloudKitContainer.Event) {
        switch event.type {
        case .setup:
            operation = .setup
        case .import:
            operation = .import
        case .export:
            operation = .export
        @unknown default:
            return nil
        }

        id = event.identifier
        startedAt = event.startDate
        endedAt = event.endDate
        succeeded = event.succeeded
        failure = CloudArchiveFailure.classify(event.error)
    }
}

enum CloudArchiveStatusAction: Equatable, Sendable {
    case accountCheckStarted
    case accountStateReceived(CloudArchiveAccountState)
    case eventObserved(CloudArchiveObservedEvent)
}

enum CloudArchiveStatusReducer {
    static func reduce(
        _ snapshot: CloudArchiveStatusSnapshot,
        action: CloudArchiveStatusAction
    ) -> CloudArchiveStatusSnapshot {
        var result = snapshot

        switch action {
        case .accountCheckStarted:
            result.accountState = .checking

        case .accountStateReceived(let accountState):
            result.accountState = accountState

        case .eventObserved(let event):
            guard let endedAt = event.endedAt else {
                result.activeEvents[event.id] = CloudArchiveActiveEvent(
                    operation: event.operation,
                    startedAt: event.startedAt
                )
                result.lastIssue = nil
                return result
            }

            result.activeEvents.removeValue(forKey: event.id)
            if event.succeeded {
                if event.operation == .export {
                    if let priorExport = result.lastSuccessfulExport {
                        result.lastSuccessfulExport = max(priorExport, endedAt)
                    } else {
                        result.lastSuccessfulExport = endedAt
                    }
                } else if event.operation == .import {
                    if let priorImport = result.lastSuccessfulImport {
                        result.lastSuccessfulImport = max(priorImport, endedAt)
                    } else {
                        result.lastSuccessfulImport = endedAt
                    }
                }

                if case .operationFailed(let operation, _)? = result.lastIssue,
                   operation == event.operation {
                    result.lastIssue = nil
                }
            } else {
                result.lastIssue = .operationFailed(event.operation, event.failure)
            }
        }

        return result
    }
}

protocol CloudArchiveAccountStatusProviding {
    func fetchAccountState() async -> CloudArchiveAccountState
}

struct SystemCloudArchiveAccountStatusProvider: CloudArchiveAccountStatusProviding {
    private let container: CKContainer

    init(container: CKContainer = .default()) {
        self.container = container
    }

    func fetchAccountState() async -> CloudArchiveAccountState {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, error in
                guard error == nil else {
                    continuation.resume(returning: .couldNotDetermine)
                    return
                }

                let state: CloudArchiveAccountState
                switch status {
                case .available:
                    state = .available
                case .noAccount:
                    state = .noAccount
                case .restricted:
                    state = .restricted
                case .temporarilyUnavailable:
                    state = .temporarilyUnavailable
                case .couldNotDetermine:
                    state = .couldNotDetermine
                @unknown default:
                    state = .couldNotDetermine
                }
                continuation.resume(returning: state)
            }
        }
    }
}

@MainActor
final class CloudArchiveStatusMonitor: ObservableObject {
    nonisolated static let defaultLastSuccessfulExportKey = "LoreCloudArchiveLastSuccessfulExport"

    @Published private(set) var status: CloudArchiveStatusSnapshot

    private let accountStatusProvider: any CloudArchiveAccountStatusProviding
    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let lastSuccessfulExportKey: String
    private var notificationToken: NSObjectProtocol?

    init(
        accountStatusProvider: any CloudArchiveAccountStatusProviding = SystemCloudArchiveAccountStatusProvider(),
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard,
        lastSuccessfulExportKey: String = CloudArchiveStatusMonitor.defaultLastSuccessfulExportKey,
        startsImmediately: Bool = true
    ) {
        self.accountStatusProvider = accountStatusProvider
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.lastSuccessfulExportKey = lastSuccessfulExportKey
        self.status = CloudArchiveStatusSnapshot(
            lastSuccessfulExport: Self.readLastSuccessfulExport(
                from: userDefaults,
                key: lastSuccessfulExportKey
            )
        )

        if startsImmediately {
            start()
        }
    }

    deinit {
        if let notificationToken {
            notificationCenter.removeObserver(notificationToken)
        }
    }

    func start(refreshesAccount: Bool = true) {
        if notificationToken == nil {
            notificationToken = notificationCenter.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event,
                      let observedEvent = CloudArchiveObservedEvent(event) else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.record(observedEvent)
                }
            }
        }

        if refreshesAccount {
            Task { [weak self] in
                await self?.refreshAccountStatus()
            }
        }
    }

    func stop() {
        guard let notificationToken else { return }
        notificationCenter.removeObserver(notificationToken)
        self.notificationToken = nil
    }

    func refreshAccountStatus() async {
        apply(.accountCheckStarted)
        let accountState = await accountStatusProvider.fetchAccountState()
        apply(.accountStateReceived(accountState))
    }

    /// Accepts a value event so status behavior is testable without CloudKit.
    func record(_ event: CloudArchiveObservedEvent) {
        apply(.eventObserved(event))
    }

    private func apply(_ action: CloudArchiveStatusAction) {
        let priorExport = status.lastSuccessfulExport
        status = CloudArchiveStatusReducer.reduce(status, action: action)

        guard status.lastSuccessfulExport != priorExport,
              let lastSuccessfulExport = status.lastSuccessfulExport else {
            return
        }

        userDefaults.set(
            lastSuccessfulExport.timeIntervalSince1970,
            forKey: lastSuccessfulExportKey
        )
    }

    private static func readLastSuccessfulExport(
        from userDefaults: UserDefaults,
        key: String
    ) -> Date? {
        if let date = userDefaults.object(forKey: key) as? Date {
            return date
        }

        guard userDefaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: userDefaults.double(forKey: key))
    }
}
