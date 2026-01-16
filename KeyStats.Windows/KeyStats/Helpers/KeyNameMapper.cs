using System.Windows.Forms;

namespace KeyStats.Helpers;

public static class KeyNameMapper
{
    private static readonly Dictionary<int, string> VirtualKeyNames = new()
    {
        // Function keys
        { 0x70, "F1" }, { 0x71, "F2" }, { 0x72, "F3" }, { 0x73, "F4" },
        { 0x74, "F5" }, { 0x75, "F6" }, { 0x76, "F7" }, { 0x77, "F8" },
        { 0x78, "F9" }, { 0x79, "F10" }, { 0x7A, "F11" }, { 0x7B, "F12" },

        // Navigation keys
        { 0x21, "PageUp" }, { 0x22, "PageDown" },
        { 0x23, "End" }, { 0x24, "Home" },
        { 0x25, "Left" }, { 0x26, "Up" }, { 0x27, "Right" }, { 0x28, "Down" },
        { 0x2D, "Insert" }, { 0x2E, "Delete" },

        // Special keys
        { 0x08, "Backspace" }, { 0x09, "Tab" }, { 0x0D, "Enter" },
        { 0x1B, "Esc" }, { 0x20, "Space" },
        { 0x13, "Pause" }, { 0x14, "CapsLock" },
        { 0x90, "NumLock" }, { 0x91, "ScrollLock" },
        { 0x2C, "PrintScreen" },

        // Modifier keys
        { 0x10, "Shift" }, { 0x11, "Ctrl" }, { 0x12, "Alt" },
        { 0xA0, "LShift" }, { 0xA1, "RShift" },
        { 0xA2, "LCtrl" }, { 0xA3, "RCtrl" },
        { 0xA4, "LAlt" }, { 0xA5, "RAlt" },
        { 0x5B, "Win" }, { 0x5C, "Win" },

        // Numpad
        { 0x60, "Num0" }, { 0x61, "Num1" }, { 0x62, "Num2" }, { 0x63, "Num3" },
        { 0x64, "Num4" }, { 0x65, "Num5" }, { 0x66, "Num6" }, { 0x67, "Num7" },
        { 0x68, "Num8" }, { 0x69, "Num9" },
        { 0x6A, "Num*" }, { 0x6B, "Num+" }, { 0x6D, "Num-" },
        { 0x6E, "Num." }, { 0x6F, "Num/" },

        // Media keys
        { 0xAD, "VolMute" }, { 0xAE, "VolDown" }, { 0xAF, "VolUp" },
        { 0xB0, "NextTrack" }, { 0xB1, "PrevTrack" },
        { 0xB2, "Stop" }, { 0xB3, "PlayPause" },

        // Browser keys
        { 0xA6, "BrowserBack" }, { 0xA7, "BrowserForward" },
        { 0xA8, "BrowserRefresh" }, { 0xA9, "BrowserStop" },
        { 0xAA, "BrowserSearch" }, { 0xAB, "BrowserFavorites" },
        { 0xAC, "BrowserHome" },

        // Application keys
        { 0x5D, "Apps" }
    };

    private static readonly HashSet<int> NavigationKeys = new()
    {
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E
    };

    private static readonly HashSet<int> ModifierVkCodes = new()
    {
        0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C
    };

    public static string GetKeyName(int vkCode)
    {
        var baseName = GetBaseKeyName(vkCode);
        var modifiers = GetModifierNames(vkCode);

        if (modifiers.Count == 0)
        {
            return baseName;
        }

        return string.Join("+", modifiers) + "+" + baseName;
    }

    private static string GetBaseKeyName(int vkCode)
    {
        if (VirtualKeyNames.TryGetValue(vkCode, out var name))
        {
            return name;
        }

        // Letter keys (A-Z)
        if (vkCode >= 0x41 && vkCode <= 0x5A)
        {
            return ((char)vkCode).ToString();
        }

        // Number keys (0-9)
        if (vkCode >= 0x30 && vkCode <= 0x39)
        {
            return ((char)vkCode).ToString();
        }

        // OEM keys
        switch (vkCode)
        {
            case 0xBA: return ";";
            case 0xBB: return "=";
            case 0xBC: return ",";
            case 0xBD: return "-";
            case 0xBE: return ".";
            case 0xBF: return "/";
            case 0xC0: return "`";
            case 0xDB: return "[";
            case 0xDC: return "\\";
            case 0xDD: return "]";
            case 0xDE: return "'";
        }

        // Try to get the key name using Windows API
        var scanCode = NativeInterop.MapVirtualKey((uint)vkCode, NativeInterop.MAPVK_VK_TO_VSC);
        if (scanCode > 0)
        {
            var keyNameBuffer = new char[32];
            var lParam = (int)(scanCode << 16);
            var result = NativeInterop.GetKeyNameText(lParam, keyNameBuffer, keyNameBuffer.Length);
            if (result > 0)
            {
                return new string(keyNameBuffer, 0, result);
            }
        }

        return $"Key{vkCode}";
    }

    private static List<string> GetModifierNames(int vkCode)
    {
        var modifiers = new List<string>();

        // Don't add modifier prefixes for modifier keys themselves
        if (ModifierVkCodes.Contains(vkCode))
        {
            return modifiers;
        }

        if (NativeInterop.IsKeyDown(NativeInterop.VK_CONTROL))
        {
            modifiers.Add("Ctrl");
        }

        if (NativeInterop.IsKeyDown(NativeInterop.VK_SHIFT))
        {
            modifiers.Add("Shift");
        }

        if (NativeInterop.IsKeyDown(NativeInterop.VK_MENU))
        {
            modifiers.Add("Alt");
        }

        if (NativeInterop.IsKeyDown(NativeInterop.VK_LWIN) || NativeInterop.IsKeyDown(NativeInterop.VK_RWIN))
        {
            modifiers.Add("Win");
        }

        return modifiers;
    }

    public static bool IsModifierKey(int vkCode)
    {
        return ModifierVkCodes.Contains(vkCode);
    }
}
