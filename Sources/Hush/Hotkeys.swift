import AppKit
import Carbon
import SwiftUI

final class Hotkeys {
    var onPress: ((String) -> Void)?
    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef?] = []
    private var ids: [UInt32: String] = [:]
    private var bindings: [String: KeyBinding] = [:]

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            var hotkey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
            if status == noErr, let id = owner.ids[hotkey.id] { owner.onPress?(id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        for hotkey in registered { if let hotkey { UnregisterEventHotKey(hotkey) } }
        if let handler { RemoveEventHandler(handler) }
    }

    @discardableResult func register(_ values: [String: KeyBinding]) -> String? {
        let old = bindings
        for hotkey in registered { if let hotkey { UnregisterEventHotKey(hotkey) } }
        registered.removeAll()
        ids.removeAll()
        for (index, pair) in values.sorted(by: { $0.key < $1.key }).enumerated() {
            let token = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(pair.value.keyCode, pair.value.modifiers,
                                             EventHotKeyID(signature: 0x48555348, id: token),
                                             GetApplicationEventTarget(), 0, &reference)
            if status != noErr {
                for hotkey in registered { if let hotkey { UnregisterEventHotKey(hotkey) } }
                registered.removeAll()
                ids.removeAll()
                if values != old { _ = register(old) }
                return "Could not register \(pair.value.label) (\(status))."
            }
            registered.append(reference)
            ids[token] = pair.key
        }
        bindings = values
        return nil
    }
}

final class RecorderButton: NSButton {
    var captured: ((KeyBinding?) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; captured?(nil); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers != 0 else { return }
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return }
        let symbols = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                    + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        recording = false
        captured?(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: symbols + key))
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let binding: KeyBinding?
    let onChange: (KeyBinding?) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.captured = onChange
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = binding?.label ?? "Set shortcut"
        button.captured = onChange
    }
}
