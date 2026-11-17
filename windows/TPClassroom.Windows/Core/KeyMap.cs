namespace TPClassroom.Core;

/// <summary>Windows virtual-key codes ↔ W3C KeyboardEvent.code names (shared with the Mac apps).</summary>
static class KeyMap
{
    static readonly Dictionary<string, (ushort Vk, bool Extended)> CodeToVk = Build();
    static readonly Dictionary<ushort, string> VkToCode = BuildReverse();

    static Dictionary<string, (ushort, bool)> Build()
    {
        var map = new Dictionary<string, (ushort, bool)>();
        for (char c = 'A'; c <= 'Z'; c++) map["Key" + c] = ((ushort)c, false);
        for (int d = 0; d <= 9; d++) map["Digit" + d] = ((ushort)('0' + d), false);
        for (int f = 1; f <= 12; f++) map["F" + f] = ((ushort)(0x6F + f), false);
        for (int n = 0; n <= 9; n++) map["Numpad" + n] = ((ushort)(0x60 + n), false);

        map["Enter"] = (0x0D, false);
        map["Escape"] = (0x1B, false);
        map["Backspace"] = (0x08, false);
        map["Tab"] = (0x09, false);
        map["Space"] = (0x20, false);
        map["Minus"] = (0xBD, false);
        map["Equal"] = (0xBB, false);
        map["BracketLeft"] = (0xDB, false);
        map["BracketRight"] = (0xDD, false);
        map["Backslash"] = (0xDC, false);
        map["Semicolon"] = (0xBA, false);
        map["Quote"] = (0xDE, false);
        map["Backquote"] = (0xC0, false);
        map["Comma"] = (0xBC, false);
        map["Period"] = (0xBE, false);
        map["Slash"] = (0xBF, false);
        map["IntlBackslash"] = (0xE2, false);
        map["CapsLock"] = (0x14, false);
        map["ArrowLeft"] = (0x25, true);
        map["ArrowUp"] = (0x26, true);
        map["ArrowRight"] = (0x27, true);
        map["ArrowDown"] = (0x28, true);
        map["Home"] = (0x24, true);
        map["End"] = (0x23, true);
        map["PageUp"] = (0x21, true);
        map["PageDown"] = (0x22, true);
        map["Insert"] = (0x2D, true);
        map["Delete"] = (0x2E, true);
        map["ShiftLeft"] = (0xA0, false);
        map["ShiftRight"] = (0xA1, false);
        map["ControlLeft"] = (0xA2, false);
        map["ControlRight"] = (0xA3, true);
        map["AltLeft"] = (0xA4, false);
        map["AltRight"] = (0xA5, true);
        map["MetaLeft"] = (0x5B, true);
        map["MetaRight"] = (0x5C, true);
        map["NumpadMultiply"] = (0x6A, false);
        map["NumpadAdd"] = (0x6B, false);
        map["NumpadSubtract"] = (0x6D, false);
        map["NumpadDecimal"] = (0x6E, false);
        map["NumpadDivide"] = (0x6F, true);
        return map;
    }

    static Dictionary<ushort, string> BuildReverse()
    {
        var map = new Dictionary<ushort, string>();
        foreach (var (code, value) in CodeToVk) map.TryAdd(value.Vk, code);
        // WinForms reports the generic modifier keys.
        map[0x10] = "ShiftLeft";
        map[0x11] = "ControlLeft";
        map[0x12] = "AltLeft";
        return map;
    }

    public static bool TryGetVk(string code, out ushort vk, out bool extended)
    {
        if (CodeToVk.TryGetValue(code, out var value))
        {
            vk = value.Vk;
            extended = value.Extended;
            return true;
        }
        vk = 0;
        extended = false;
        return false;
    }

    public static string? CodeFromKeys(Keys key) =>
        VkToCode.TryGetValue((ushort)(key & Keys.KeyCode), out var code) ? code : null;

    /// <summary>When teacher and student use different systems, ⌘/⊞ and Ctrl trade places.</summary>
    public static string SwapMetaAndControl(string code) => code switch
    {
        "MetaLeft" => "ControlLeft",
        "MetaRight" => "ControlRight",
        "ControlLeft" => "MetaLeft",
        "ControlRight" => "MetaRight",
        _ => code,
    };

    public static int SwapMetaAndControl(int mods)
    {
        int result = mods & ~(Mods.Meta | Mods.Control);
        if ((mods & Mods.Meta) != 0) result |= Mods.Control;
        if ((mods & Mods.Control) != 0) result |= Mods.Meta;
        return result;
    }
}
