import Foundation

struct PaintingRevision: Hashable, Sendable {
    let id: UUID
    let updatedAt: Date
    let fingerprint: String
}

/// One claim per locally generated revision, shared by the app's picture surfaces.
@MainActor
final class PaintingRevealSession {
    private var pending: [String: PaintingRevision] = [:]
    private var shown: Set<PaintingRevision> = []

    func register(_ revision: PaintingRevision, for key: String) {
        guard !shown.contains(revision) else { return }
        pending[key] = revision
    }

    func pendingRevision(for key: String) -> PaintingRevision? {
        pending[key]
    }

    func claim(_ revision: PaintingRevision, for key: String) -> Bool {
        guard pending[key] == revision else { return false }
        pending.removeValue(forKey: key)
        shown.insert(revision)
        return true
    }
}
