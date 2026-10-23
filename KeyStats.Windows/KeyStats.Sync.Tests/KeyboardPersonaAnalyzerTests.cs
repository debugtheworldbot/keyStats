using System.Collections.Generic;
using System.Linq;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class KeyboardPersonaAnalyzerTests
{
    private static KeyboardPersonaResult Analyze(Dictionary<string, int> counts, int clicks)
    {
        return KeyboardPersonaAnalyzer.Analyze(counts, counts.Values.Sum(), clicks);
    }

    [TestMethod]
    public void BelowMinimumKeyPresses_DoesNotAssignPersona()
    {
        var result = Analyze(new Dictionary<string, int> { ["A"] = 199 }, clicks: 50);

        Assert.IsFalse(result.HasEnoughData);
        Assert.AreEqual(0, result.SecondaryPersonas.Count);
    }

    [TestMethod]
    public void ShortcutHeavy_IsShortcutMaster_AndShiftOnlyCombosAreNotShortcuts()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["A"] = 700,
            ["Shift+A"] = 150,
            ["Ctrl+S"] = 80,
            ["Alt+Tab"] = 40,
            ["Win+D"] = 30
        }, clicks: 300);

        Assert.AreEqual(150, result.ShortcutCount);
        Assert.AreEqual(KeyboardPersona.ShortcutMaster, result.Persona);
    }

    [TestMethod]
    public void PasteDominant_IsCopyPasteEngineer()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["A"] = 900,
            ["Ctrl+C"] = 10,
            ["Ctrl+V"] = 40,
            ["Ctrl+Z"] = 5
        }, clicks: 400);

        Assert.AreEqual(10, result.CopyCount);
        Assert.AreEqual(40, result.PasteCount);
        Assert.AreEqual(5, result.UndoCount);
        // 快捷键占比 55/955 < 12%，因此主称号落到复制粘贴
        Assert.AreEqual(KeyboardPersona.CopyPasteEngineer, result.Persona);
    }

    [TestMethod]
    public void RegretKeysIncludeModifiedBackspaceAndDelete()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["A"] = 800,
            ["Backspace"] = 80,
            ["Ctrl+Backspace"] = 10,
            ["Delete"] = 20
        }, clicks: 400);

        Assert.AreEqual(110, result.RegretCount);
        Assert.AreEqual(KeyboardPersona.Perfectionist, result.Persona);
    }

    [TestMethod]
    public void ArrowHeavy_IsArrowKeyWalker()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["A"] = 900,
            ["Up"] = 50,
            ["Shift+Down"] = 50
        }, clicks: 400);

        Assert.AreEqual(100, result.ArrowCount);
        Assert.AreEqual(KeyboardPersona.ArrowKeyWalker, result.Persona);
    }

    [TestMethod]
    [DataRow(1000, KeyboardPersona.MousePerson)]
    [DataRow(150, KeyboardPersona.KeyboardPurist)]
    [DataRow(500, KeyboardPersona.BalancedPlayer)]
    public void ClickRatio_DecidesMouseOrKeyboardOrBalanced(int clicks, KeyboardPersona expected)
    {
        var result = Analyze(new Dictionary<string, int> { ["A"] = 1000 }, clicks);

        Assert.AreEqual(expected, result.Persona);
    }

    [TestMethod]
    public void MultipleMatches_FirstIsPrimaryRestAreSecondary()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["A"] = 600,
            ["Ctrl+S"] = 200,
            ["Backspace"] = 200
        }, clicks: 50);

        Assert.AreEqual(KeyboardPersona.ShortcutMaster, result.Persona);
        CollectionAssert.AreEqual(
            new[] { KeyboardPersona.Perfectionist, KeyboardPersona.KeyboardPurist },
            result.SecondaryPersonas.ToArray());
    }

    [TestMethod]
    public void TopKeys_ExcludeSpace()
    {
        var result = Analyze(new Dictionary<string, int>
        {
            ["Space"] = 500,
            ["E"] = 300,
            ["T"] = 200,
            ["A"] = 100,
            ["Q"] = 1
        }, clicks: 400);

        CollectionAssert.AreEqual(new[] { "E", "T", "A" }, result.TopKeys.Select(k => k.Key).ToArray());
    }
}
