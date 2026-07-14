using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace KeyStats.Services;

internal static class SyncKeyCanonicalizer
{
    private static readonly Regex FunctionKeyPattern = new("^F[0-9]{1,2}$", RegexOptions.CultureInvariant);

    public static string Canonicalize(string? rawName, string platform)
    {
        var trimmed = (rawName ?? string.Empty).Trim();
        if (trimmed.Length == 0) return string.Empty;
        if (trimmed == "+") return "+";

        var source = trimmed;
        var hasLiteralPlus = source.EndsWith("++", StringComparison.Ordinal);
        if (hasLiteralPlus) source = source.Substring(0, source.Length - 1);

        var normalized = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawPart in source.Split(new[] { '+' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var part = CanonicalPart(rawPart, platform);
            if (part.Length > 0 && seen.Add(part)) normalized.Add(part);
        }
        if (hasLiteralPlus && seen.Add("+")) normalized.Add("+");
        return string.Join("+", normalized);
    }

    private static string CanonicalPart(string raw, string platform)
    {
        var value = (raw ?? string.Empty).Trim();
        var upper = value.ToUpperInvariant();
        switch (upper)
        {
            case "ESC": case "ESCAPE": return "Esc";
            case "RETURN": case "ENTER": case "NUMPADENTER": return "Enter";
            case "BACKSPACE": case "BS": return "Backspace";
            case "DELETE": case "DEL": case "FORWARDDELETE": return "Delete";
            case "LEFT": case "ARROWLEFT": case "LEFTARROW": return "Left";
            case "RIGHT": case "ARROWRIGHT": case "RIGHTARROW": return "Right";
            case "UP": case "ARROWUP": case "UPARROW": return "Up";
            case "DOWN": case "ARROWDOWN": case "DOWNARROW": return "Down";
            case "COMMAND": case "CMD": return "Cmd";
            case "LEFTCOMMAND": case "LEFTCMD": return "LeftCmd";
            case "RIGHTCOMMAND": case "RIGHTCMD": return "RightCmd";
            case "WINDOWS": case "WIN": case "META": return "Win";
            case "LEFTWINDOWS": case "LEFTWIN": return "LeftWin";
            case "RIGHTWINDOWS": case "RIGHTWIN": return "RightWin";
            case "OPTION": return "Option";
            case "LEFTOPTION": return "LeftOption";
            case "RIGHTOPTION": return "RightOption";
            case "ALT": return "Alt";
            case "LEFTALT": return "LeftAlt";
            case "RIGHTALT": return "RightAlt";
            case "CONTROL": case "CTRL": return "Ctrl";
            case "LEFTCONTROL": case "LEFTCTRL": return "LeftCtrl";
            case "RIGHTCONTROL": case "RIGHTCTRL": return "RightCtrl";
            case "SHIFT": return "Shift";
            case "LEFTSHIFT": return "LeftShift";
            case "RIGHTSHIFT": return "RightShift";
            case "FN": case "FUNCTION": case "GLOBE": case "🌐": case "KEY63": case "KEY179": return "Fn";
            case "SPACE": case "SPACEBAR": return "Space";
            case "TAB": return "Tab";
            case "CAPS": case "CAPSLOCK": return "CapsLock";
            case "INSERT": case "INS": case "HELP": return "Insert";
            case "PAGEUP": return "PageUp";
            case "PAGEDOWN": return "PageDown";
            case "HOME": return "Home";
            case "END": return "End";
            case "PRINTSCREEN": case "PRTSC": case "PRTSCN": case "SNAPSHOT": return "PrintScreen";
            case "SCROLLLOCK": case "SCROLL": return "ScrollLock";
            case "PAUSE": case "BREAK": return "Pause";
            case "+": return "+";
        }

        if (StringInfo.ParseCombiningCharacters(value).Length == 1 || FunctionKeyPattern.IsMatch(upper)) return upper;
        if ((value.StartsWith("mac:", StringComparison.Ordinal) && value.Length > 4) ||
            (value.StartsWith("macos:", StringComparison.Ordinal) && value.Length > 6) ||
            (value.StartsWith("windows:", StringComparison.Ordinal) && value.Length > 8))
        {
            return value;
        }
        return platform + ":" + value;
    }
}
