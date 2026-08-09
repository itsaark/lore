import CloudKit
import Foundation
import Testing
@testable import lore

@Suite(.serialized)
@MainActor
struct CloudArchiveStatusMonitorTests {
    @Test func availableAccountDoesNotClaimAnExport() async throws {
        let defaults = try makeDefaults()
        let monitor = CloudArchiveStatusMonitor(
            accountStatusProvider: FixedCloudArchiveAccountProvider(.available),
            userDefaults: defaults,
            startsImmediately: false
        )

        await monitor.refreshAccountStatus()

        #expect(monitor.status.accountState == .available)
        #expect(monitor.status.lastSuccessfulExport == nil)
        #expect(!monitor.status.hasObservedSuccessfulExport)
        #expect(monitor.status.displayState == .readyToSync)
    }

    @Test func importDoesNotCountAsAConfirmedExport() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let eventID = UUID()
        var snapshot = CloudArchiveStatusSnapshot(accountState: .available)

        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: eventID,
                operation: .import,
                startedAt: start
            ))
        )
        #expect(snapshot.displayState == .restoring(lastSuccessfulExport: nil))

        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: eventID,
                operation: .import,
                startedAt: start,
                endedAt: start.addingTimeInterval(4),
                succeeded: true
            ))
        )

        #expect(snapshot.lastSuccessfulExport == nil)
        #expect(snapshot.lastSuccessfulImport == start.addingTimeInterval(4))
        #expect(!snapshot.hasObservedSuccessfulExport)
        #expect(snapshot.displayState == .readyToSync)
    }

    @Test func completedExportIsPersistedAndRestored() async throws {
        let defaults = try makeDefaults()
        let key = "last-export-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(7)
        let eventID = UUID()
        let monitor = CloudArchiveStatusMonitor(
            accountStatusProvider: FixedCloudArchiveAccountProvider(.available),
            userDefaults: defaults,
            lastSuccessfulExportKey: key,
            startsImmediately: false
        )
        await monitor.refreshAccountStatus()

        monitor.record(CloudArchiveObservedEvent(
            id: eventID,
            operation: .export,
            startedAt: start
        ))
        #expect(monitor.status.displayState == .syncing(lastSuccessfulExport: nil))
        #expect(!monitor.status.hasObservedSuccessfulExport)

        monitor.record(CloudArchiveObservedEvent(
            id: eventID,
            operation: .export,
            startedAt: start,
            endedAt: end,
            succeeded: true
        ))

        #expect(monitor.status.lastSuccessfulExport == end)
        #expect(monitor.status.hasObservedSuccessfulExport)
        #expect(monitor.status.displayState == .synced(lastSuccessfulExport: end))
        #expect(defaults.double(forKey: key) == end.timeIntervalSince1970)

        let restoredMonitor = CloudArchiveStatusMonitor(
            accountStatusProvider: FixedCloudArchiveAccountProvider(.available),
            userDefaults: defaults,
            lastSuccessfulExportKey: key,
            startsImmediately: false
        )
        await restoredMonitor.refreshAccountStatus()

        #expect(restoredMonitor.status.lastSuccessfulExport == end)
        #expect(restoredMonitor.status.displayState == .synced(lastSuccessfulExport: end))
    }

    @Test func failedExportPreservesThePriorSuccessAndReportsAPause() throws {
        let priorExport = Date(timeIntervalSince1970: 1_799_000_000)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let eventID = UUID()
        var snapshot = CloudArchiveStatusSnapshot(
            accountState: .available,
            lastSuccessfulExport: priorExport
        )

        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: eventID,
                operation: .export,
                startedAt: start
            ))
        )
        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: eventID,
                operation: .export,
                startedAt: start,
                endedAt: start.addingTimeInterval(5),
                succeeded: false,
                failure: .networkUnavailable
            ))
        )

        let issue = CloudArchiveStatusIssue.operationFailed(.export, .networkUnavailable)
        #expect(snapshot.lastSuccessfulExport == priorExport)
        #expect(snapshot.lastIssue == issue)
        #expect(snapshot.displayState == .paused(issue, lastSuccessfulExport: priorExport))
    }

    @Test func overlappingEventsRemainActiveUntilEachOneFinishes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let importID = UUID()
        let exportID = UUID()
        var snapshot = CloudArchiveStatusSnapshot(accountState: .available)

        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: importID,
                operation: .import,
                startedAt: start
            ))
        )
        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: exportID,
                operation: .export,
                startedAt: start.addingTimeInterval(1)
            ))
        )
        #expect(snapshot.activeOperation == .export)

        snapshot = CloudArchiveStatusReducer.reduce(
            snapshot,
            action: .eventObserved(CloudArchiveObservedEvent(
                id: exportID,
                operation: .export,
                startedAt: start.addingTimeInterval(1),
                endedAt: start.addingTimeInterval(3),
                succeeded: true
            ))
        )

        #expect(snapshot.activeOperation == .import)
        #expect(snapshot.displayState == .restoring(lastSuccessfulExport: start.addingTimeInterval(3)))
    }

    @Test func accountProblemsTakePrecedenceWithoutErasingExportHistory() {
        let lastExport = Date(timeIntervalSince1970: 1_800_000_000)

        for accountState in [
            CloudArchiveAccountState.noAccount,
            .restricted,
            .temporarilyUnavailable,
            .couldNotDetermine
        ] {
            let snapshot = CloudArchiveStatusSnapshot(
                accountState: accountState,
                lastSuccessfulExport: lastExport
            )

            #expect(snapshot.hasObservedSuccessfulExport)
            #expect(snapshot.displayState == .accountUnavailable(
                accountState,
                lastSuccessfulExport: lastExport
            ))
        }
    }

    @Test func cloudKitErrorsAreReducedToContentFreeFailureCategories() {
        let networkError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkUnavailable.rawValue
        )
        let quotaError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.quotaExceeded.rawValue
        )
        let wrappedError = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSUnderlyingErrorKey: quotaError]
        )

        #expect(CloudArchiveFailure.classify(networkError) == .networkUnavailable)
        #expect(CloudArchiveFailure.classify(wrappedError) == .quotaExceeded)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CloudArchiveStatusMonitorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private struct FixedCloudArchiveAccountProvider: CloudArchiveAccountStatusProviding {
    let state: CloudArchiveAccountState

    init(_ state: CloudArchiveAccountState) {
        self.state = state
    }

    func fetchAccountState() async -> CloudArchiveAccountState {
        state
    }
}
