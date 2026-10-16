import AppKit
import Carbon

final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier: UInt32
    var onActivate: (() -> Void)?

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.id == shortcut.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { shortcut.onActivate?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var replacement: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x50415354, id: identifier)
        let result = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
