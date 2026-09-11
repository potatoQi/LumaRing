import AppKit
import Carbon

struct AppAction: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var shortcut: Shortcut?
    var displayName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
    var configured: Bool { !displayName.isEmpty && shortcut.map(Self.validShortcut) == true }

    static func validShortcut(_ shortcut: Shortcut) -> Bool {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return shortcut.keyCode < 128 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(shortcut.keyCode)
            && shortcut.modifiers & ~modifiers == 0
    }
    func conflicts(with invocation: Shortcut) -> Bool {
        shortcut?.keyCode == invocation.keyCode && shortcut?.modifiers == invocation.modifiers
    }
}

struct ActionProfile: Codable, Equatable, Identifiable {
    var app: LauncherApp
    var actions: [AppAction] = []
    var id: String { app.bundleID }

    mutating func move(_ id: String, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }), actions.indices.contains(index + offset) else { return }
        actions.swapAt(index, index + offset)
    }
    static func normalized(_ profiles: [ActionProfile]) -> [ActionProfile] {
        var apps = Set<String>()
        return profiles.filter { !$0.id.isEmpty && apps.insert($0.id).inserted }.prefix(64).map { profile in
            var profile = profile, ids = Set<String>()
            profile.actions = Array(profile.actions.filter { ids.insert($0.id).inserted }.prefix(48))
            return profile
        }
    }
}

/// Two complete, unmodified left-Option taps. Chords, right Option and long
/// holds break the sequence; invocation's already-held Option cannot count.
struct LeftOptionDoubleTap {
    // Use the same boundary for tap recognition and launcher hold presentation.
    static let holdDelay: TimeInterval = 0.15
    private var down: TimeInterval?
    private var firstUp: TimeInterval?
    private(set) var isDown = false
    mutating func reset() { down = nil; firstUp = nil; isDown = false }
    mutating func update(left: Bool, pressed: Bool, otherModifiers: Bool, time: TimeInterval) -> Bool {
        guard left, !otherModifiers, time.isFinite else { reset(); return false }
        if pressed {
            guard !isDown else { return false }
            isDown = true; down = time
            if let firstUp, time < firstUp || time - firstUp > 0.35 { self.firstUp = nil }
            return false
        }
        isDown = false
        guard let down, time >= down, time - down <= Self.holdDelay else { reset(); return false }
        self.down = nil
        if let firstUp, time - firstUp <= 0.55 { reset(); return true }
        firstUp = time
        return false
    }
}
