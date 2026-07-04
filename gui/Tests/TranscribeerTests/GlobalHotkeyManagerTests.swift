import Carbon
import Testing
@testable import TranscribeerApp

struct GlobalHotkeyManagerTests {
    // MARK: - HotkeyDescriptor.parse

    @Test("Parse default hotkey string")
    func parseDefault() throws {
        let desc = try #require(HotkeyDescriptor.parse("cmd+shift+t"))
        #expect(desc.keyCode == UInt32(kVK_ANSI_T))
        #expect(desc.modifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("Parse returns nil for empty string")
    func parseEmpty() {
        #expect(HotkeyDescriptor.parse("") == nil)
    }

    @Test("Parse returns nil for unrecognised key")
    func parseUnknown() {
        #expect(HotkeyDescriptor.parse("cmd+shift+esc") == nil)
    }

    @Test("Parse single modifier + letter")
    func parseSingleMod() throws {
        let desc = try #require(HotkeyDescriptor.parse("cmd+a"))
        #expect(desc.keyCode == UInt32(kVK_ANSI_A))
        #expect(desc.modifiers == UInt32(cmdKey))
    }

    @Test("Parse is case-insensitive")
    func parseCaseInsensitive() throws {
        let lower = try #require(HotkeyDescriptor.parse("cmd+shift+t"))
        let upper = try #require(HotkeyDescriptor.parse("CMD+SHIFT+T"))
        #expect(lower == upper)
    }

    @Test("Parse option key variants", arguments: ["opt", "option", "alt"])
    func parseOptionVariants(keyword: String) throws {
        let desc = try #require(HotkeyDescriptor.parse("\(keyword)+t"))
        #expect(desc.modifiers & UInt32(optionKey) != 0)
    }

    @Test("Parse ctrl key variants", arguments: ["ctrl", "control"])
    func parseCtrlVariants(keyword: String) throws {
        let desc = try #require(HotkeyDescriptor.parse("\(keyword)+t"))
        #expect(desc.modifiers & UInt32(controlKey) != 0)
    }

    @Test("Parse cmd+command are aliases")
    func parseCmdAlias() throws {
        let viaCmd = try #require(HotkeyDescriptor.parse("cmd+t"))
        let viaCommand = try #require(HotkeyDescriptor.parse("command+t"))
        #expect(viaCmd == viaCommand)
    }

    @Test("Parse function key")
    func parseFunctionKey() throws {
        let desc = try #require(HotkeyDescriptor.parse("cmd+f1"))
        #expect(desc.keyCode == UInt32(kVK_F1))
    }

    @Test("Parse number key")
    func parseNumberKey() throws {
        let desc = try #require(HotkeyDescriptor.parse("shift+1"))
        #expect(desc.keyCode == UInt32(kVK_ANSI_1))
    }

    // MARK: - HotkeyDescriptor.displayString

    @Test("Display string for cmd+shift+t")
    func displayStringCmdShiftT() throws {
        let desc = try #require(HotkeyDescriptor.parse("cmd+shift+t"))
        #expect(desc.displayString == "⇧⌘T")
    }

    @Test("Display string shows ctrl modifier")
    func displayStringCtrl() throws {
        let desc = try #require(HotkeyDescriptor.parse("ctrl+t"))
        #expect(desc.displayString.contains("⌃"))
    }

    @Test("Display string shows opt modifier")
    func displayStringOpt() throws {
        let desc = try #require(HotkeyDescriptor.parse("opt+t"))
        #expect(desc.displayString.contains("⌥"))
    }

    // MARK: - HotkeyDescriptor.configString round-trip

    @Test("configString round-trips through parse")
    func configStringRoundTrip() throws {
        let original = "cmd+shift+t"
        let desc = try #require(HotkeyDescriptor.parse(original))
        let roundTripped = try #require(HotkeyDescriptor.parse(desc.configString))
        #expect(roundTripped == desc)
    }

    @Test("configString round-trip for cmd+a")
    func configStringRoundTripCmdA() throws {
        let desc = try #require(HotkeyDescriptor.parse("cmd+a"))
        let roundTripped = try #require(HotkeyDescriptor.parse(desc.configString))
        #expect(roundTripped == desc)
    }
}
