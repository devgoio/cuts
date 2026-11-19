import Foundation

struct HistoryPasteDelivery {
    enum Decision { case superseded, clipboardChanged, targetUnavailable, send, wait }
    let id = UUID()
    let target: pid_t
    let changeCount: Int

    func decision(active: UUID?, changeCount: Int, foreground: pid_t?, targetAlive: Bool, remaining: Int) -> Decision {
        guard active == id else { return .superseded }
        guard changeCount == self.changeCount else { return .clipboardChanged }
        guard targetAlive else { return .targetUnavailable }
        if foreground == target { return .send }
        return remaining > 0 ? .wait : .targetUnavailable
    }

    static func verify() -> Bool {
        let delivery = Self(target: 55, changeCount: 12)
        func decide(_ active: UUID?, _ count: Int, _ foreground: pid_t?, _ alive: Bool, _ remaining: Int) -> Decision {
            delivery.decision(active: active, changeCount: count, foreground: foreground, targetAlive: alive, remaining: remaining)
        }
        return decide(delivery.id, 12, 55, true, 1) == .send
            && decide(delivery.id, 12, 77, true, 1) == .wait
            && decide(delivery.id, 12, 77, true, 0) == .targetUnavailable
            && decide(delivery.id, 12, 55, false, 1) == .targetUnavailable
            && decide(delivery.id, 13, 55, true, 1) == .clipboardChanged
            && decide(UUID(), 12, 55, true, 1) == .superseded
    }
}
