import Carbon
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "hotkey")

// MARK: - Error

enum GlobalHotkeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            "Failed to register global hotkey (OSStatus \(status)). "
                + "Another app may already own this key combination."
        }
    }
}

// MARK: - HotkeyDescriptor

/// Parsed representation of a hotkey string like `"cmd+shift+t"`.
struct HotkeyDescriptor: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    // MARK: Parse

    /// Parse a string like `"cmd+shift+t"` into a `HotkeyDescriptor`.
    /// Returns `nil` for unrecognised strings.
    static func parse(_ string: String) -> Self? {
        guard !string.isEmpty else { return nil }
        let parts = string.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }

        let keyPart = parts.last ?? ""
        let modParts = parts.dropLast()

        var modifiers: UInt32 = 0
        for mod in modParts {
            switch mod {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: return nil
            }
        }

        guard let keyCode = keyCodeForString(keyPart) else { return nil }
        return Self(keyCode: keyCode, modifiers: modifiers)
    }

    /// Human-readable display string (e.g. `"⌘⇧T"`).
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyCodeToDisplayString(keyCode)
        return result
    }

    // MARK: - Encode

    /// Serialise back to config string (e.g. `"cmd+shift+t"`).
    var configString: String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("opt") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        parts.append(keyCodeToConfigString(keyCode))
        return parts.joined(separator: "+")
    }
}

// MARK: - Key code helpers

private func keyCodeForString(_ key: String) -> UInt32? {
    // Letter keys
    let letters: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]
    if let code = letters[key] { return UInt32(code) }

    // Number keys
    let numbers: [String: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]
    if let code = numbers[key] { return UInt32(code) }

    // Function keys
    let fnKeys: [String: Int] = [
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
    if let code = fnKeys[key] { return UInt32(code) }

    return nil
}

private func keyCodeToDisplayString(_ keyCode: UInt32) -> String {
    let map: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
    return map[Int(keyCode)] ?? "?"
}

private func keyCodeToConfigString(_ keyCode: UInt32) -> String {
    keyCodeToDisplayString(keyCode).lowercased()
}

// MARK: - GlobalHotkeyManager

/// Manages Carbon global hotkey registrations.
///
/// Carbon `RegisterEventHotKey` works even when the app is not the frontmost
/// process — unlike `NSEvent.addGlobalMonitorForEvents`, which is suppressed
/// when the app is inactive.
///
/// Thread-safety: public methods are called from the main thread. The Carbon
/// event callback arrives on an unspecified thread and hops to `DispatchQueue.main`.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    // "TRSC" as OSType
    private let hotkeySignature: OSType = 0x54525343

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    // Stored as nonisolated(unsafe) so deinit (nonisolated) can cancel it.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    deinit {
        if let ref = eventHandler {
            RemoveEventHandler(ref)
        }
    }

    // MARK: - Public API

    /// Register a global hotkey. `handler` is dispatched on the main thread.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        // Unregister any existing binding for this id first.
        unregister(id: id)

        var hotKeyID = EventHotKeyID(signature: hotkeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let ref = hotKeyRef else {
            logger.error("RegisterEventHotKey failed: OSStatus=\(status, privacy: .public) id=\(id, privacy: .public)")
            throw GlobalHotkeyError.registrationFailed(status)
        }

        handlers[id] = handler
        hotKeyRefs[id] = ref
        logger.info("registered hotkey id=\(id, privacy: .public) keyCode=\(keyCode, privacy: .public) mods=\(modifiers, privacy: .public)")
    }

    /// Unregister a hotkey by id. No-op if not registered.
    func unregister(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
            logger.info("unregistered hotkey id=\(id, privacy: .public)")
        }
    }

    /// Unregister all registered hotkeys.
    func unregisterAll() {
        for (id, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
            logger.info("unregistered hotkey id=\(id, privacy: .public)")
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }

    // MARK: - Carbon event handler

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Capture self via unretained pointer — the handler is torn down in deinit.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleCarbonEvent(event)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        if status != noErr {
            logger.error("InstallEventHandler failed: OSStatus=\(status, privacy: .public)")
        }
    }

    private func handleCarbonEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == hotkeySignature else {
            return OSStatus(eventNotHandledErr)
        }

        let id = hotKeyID.id
        // handlers dict is only mutated on the main thread; read here is safe
        // because Carbon callbacks arrive on the main run loop in practice,
        // but we hop explicitly to be certain.
        DispatchQueue.main.async { [weak self] in
            self?.handlers[id]?()
        }
        return noErr
    }
}
