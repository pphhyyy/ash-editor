import AppKit

/// Resolve every document window before replying to AppKit's asynchronous quit.
@MainActor
final class ApplicationQuitGuard {
    static let shared = ApplicationQuitGuard()
    private struct Participant {
        weak var window: NSWindow?
        let prepare: (@escaping (Bool) -> Void) -> Void
    }
    private var participants: [UUID: Participant] = [:]

    var hasParticipants: Bool { participants.values.contains { $0.window != nil } }

    func attach(id: UUID, window: NSWindow, prepare: @escaping (@escaping (Bool) -> Void) -> Void) {
        participants[id] = Participant(window: window, prepare: prepare)
    }

    func detach(id: UUID) { participants.removeValue(forKey: id) }

    func prepareToQuit(completion: @escaping (Bool) -> Void) {
        let windows = participants.values.filter { $0.window != nil }
        func next(_ index: Int) {
            guard index < windows.count else { completion(true); return }
            NSApp.activate(ignoringOtherApps: true)
            windows[index].window?.deminiaturize(nil)
            windows[index].window?.makeKeyAndOrderFront(nil)
            windows[index].prepare { allowed in
                if allowed { next(index + 1) } else { completion(false) }
            }
        }
        next(0)
    }
}
