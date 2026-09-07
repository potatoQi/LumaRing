import AppKit
import Carbon

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var isDown = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                if !owner.isDown { owner.isDown = true; owner.onPress?() }
            } else { owner.isDown = false; owner.onRelease?() }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult func register(_ shortcut: Shortcut) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        isDown = false
        let id = EventHotKeyID(signature: 0x4C554D41, id: 1)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                  GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
