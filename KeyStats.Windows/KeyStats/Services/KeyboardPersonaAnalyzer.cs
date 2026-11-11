using System;
using System.Collections.Generic;
using System.Linq;

namespace KeyStats.Services;

public enum KeyboardPersona
{
    ShortcutMaster,
    CopyPasteEngineer,
    Perfectionist,
    ArrowKeyWalker,
    MousePerson,
    KeyboardPurist,
    BalancedPlayer
}

public sealed class KeyboardPersonaResult
{
    public bool HasEnoughData { get; set; }
    public int TotalKeys { get; set; }
    public int TotalClicks { get; set; }
    public int ShortcutCount { get; set; }
    public int RegretCount { get; set; }
    public int CopyCount { get; set; }
    public int PasteCount { get; set; }
    public int UndoCount { get; set; }
    public int ArrowCount { get; set; }
    public double ShortcutRatio { get; set; }
    public double RegretRatio { get; set; }
    public double ArrowRatio { get; set; }
    public double ClicksPerKey { get; set; }
    public IReadOnlyList<(string Key, int Count)> TopKeys { get; set; } = Array.Empty<(string, int)>();
    public KeyboardPersona Persona { get; set; } = KeyboardPersona.BalancedPlayer;
    public IReadOnlyList<KeyboardPersona> SecondaryPersonas { get; set; } = Array.Empty<KeyboardPersona>();
}

/// <summary>
/// 根据按键分布推断「键盘人格」。只做纯计算，规则与 macOS 端保持一致。
/// </summary>
public static class KeyboardPersonaAnalyzer
{
    public const int MinimumKeyPresses = 200;

    private static readonly string[] ShortcutModifiers = { "Ctrl", "Alt", "Win" };
    private static readonly HashSet<string> RegretKeys = new(StringComparer.Ordinal) { "Backspace", "Delete" };
    private static readonly HashSet<string> ArrowKeys = new(StringComparer.Ordinal) { "Up", "Down", "Left", "Right" };

    public static KeyboardPersonaResult Analyze(IReadOnlyDictionary<string, int> keyCounts, int totalKeys, int totalClicks)
    {
        var result = new KeyboardPersonaResult
        {
            TotalKeys = Math.Max(0, totalKeys),
            TotalClicks = Math.Max(0, totalClicks)
        };

        foreach (var pair in keyCounts)
        {
            if (pair.Value <= 0 || string.IsNullOrEmpty(pair.Key))
            {
                continue;
            }

            var parts = SplitKeyName(pair.Key);
            var baseKey = parts[parts.Count - 1];
            var modifiers = parts.Take(parts.Count - 1).ToList();

            if (modifiers.Any(m => ShortcutModifiers.Contains(m, StringComparer.Ordinal)))
            {
                result.ShortcutCount += pair.Value;
            }
            if (RegretKeys.Contains(baseKey))
            {
                result.RegretCount += pair.Value;
            }
            if (ArrowKeys.Contains(baseKey))
            {
                result.ArrowCount += pair.Value;
            }

            switch (pair.Key)
            {
                case "Ctrl+C":
                    result.CopyCount += pair.Value;
                    break;
                case "Ctrl+V":
                    result.PasteCount += pair.Value;
                    break;
                case "Ctrl+Z":
                    result.UndoCount += pair.Value;
                    break;
            }
        }

        result.TopKeys = keyCounts
            .Where(pair => pair.Value > 0 && !string.Equals(pair.Key, "Space", StringComparison.Ordinal))
            .OrderByDescending(pair => pair.Value)
            .ThenBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
            .Take(3)
            .Select(pair => (pair.Key, pair.Value))
            .ToList();

        if (result.TotalKeys > 0)
        {
            result.ShortcutRatio = (double)result.ShortcutCount / result.TotalKeys;
            result.RegretRatio = (double)result.RegretCount / result.TotalKeys;
            result.ArrowRatio = (double)result.ArrowCount / result.TotalKeys;
            result.ClicksPerKey = (double)result.TotalClicks / result.TotalKeys;
        }

        result.HasEnoughData = result.TotalKeys >= MinimumKeyPresses;
        if (!result.HasEnoughData)
        {
            return result;
        }

        var matched = new List<KeyboardPersona>();
        if (result.ShortcutRatio >= 0.12) matched.Add(KeyboardPersona.ShortcutMaster);
        if (result.PasteCount >= 30 && result.PasteCount >= 2 * result.CopyCount) matched.Add(KeyboardPersona.CopyPasteEngineer);
        if (result.RegretRatio >= 0.10) matched.Add(KeyboardPersona.Perfectionist);
        if (result.ArrowRatio >= 0.08) matched.Add(KeyboardPersona.ArrowKeyWalker);
        if (result.ClicksPerKey >= 1.0) matched.Add(KeyboardPersona.MousePerson);
        if (result.ClicksPerKey <= 0.15) matched.Add(KeyboardPersona.KeyboardPurist);

        result.Persona = matched.Count > 0 ? matched[0] : KeyboardPersona.BalancedPlayer;
        result.SecondaryPersonas = matched.Skip(1).ToList();
        return result;
    }

    // "Ctrl+Shift+A" → [Ctrl, Shift, A]；"Ctrl++" → [Ctrl, +]；"+" → [+]
    private static List<string> SplitKeyName(string keyName)
    {
        var parts = new List<string>();
        var raw = keyName;
        var trailingPlus = raw.Length > 1 && raw.EndsWith("++", StringComparison.Ordinal);
        if (trailingPlus)
        {
            raw = raw.Substring(0, raw.Length - 2);
        }

        if (raw.Length <= 1)
        {
            parts.Add(raw);
        }
        else
        {
            parts.AddRange(raw.Split('+').Where(p => p.Length > 0));
        }

        if (trailingPlus)
        {
            parts.Add("+");
        }
        if (parts.Count == 0)
        {
            parts.Add(keyName);
        }
        return parts;
    }
}
