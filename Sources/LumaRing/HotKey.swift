import AppKit
import Carbon

final class HotKey {
    private static var nextID: UInt32 = 0
    let id: EventHotKeyID
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var isDown = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    init() {
        Self.nextID += 1
        id = EventHotKeyID(signature: 0x4C554D41, id: Self.nextID)
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return owner.handle(id: id, kind: GetEventKind(event))
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func handle(id: EventHotKeyID, kind: UInt32) -> OSStatus {
        guard id.signature == self.id.signature, id.id == self.id.id else { return OSStatus(eventNotHandledErr) }
        if kind == UInt32(kEventHotKeyPressed) {
            if !isDown { isDown = true; onPress?() }
        } else if kind == UInt32(kEventHotKeyReleased) {
            if isDown { isDown = false; onRelease?() }
        } else { return OSStatus(eventNotHandledErr) }
        return noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        isDown = false
    }

    @discardableResult func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                  GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
