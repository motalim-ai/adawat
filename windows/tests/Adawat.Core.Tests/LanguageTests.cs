using System.Text.Json;
using System.Text.RegularExpressions;

namespace Adawat.Core.Tests;

/// <summary>Changes the app's language, so nothing else runs beside it.</summary>
[CollectionDefinition("language", DisableParallelization = true)]
public class LanguageCollection;

[Collection("language")]
public class LanguageTests
{
    private static Dictionary<string, string> Table(string name)
    {
        using var stream = typeof(L10n).Assembly.GetManifestResourceStream(name) ?? throw new InvalidOperationException($"{name} is not in the core");
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)!;
    }

    [Fact]
    public void ArabicReplacesExactTextAndTextWithValues()
    {
        L10n.Override("ar");
        try
        {
            Assert.Equal("إلغاء", L10n.T("Cancel"));
            Assert.Equal("أُلغي", L10n.T("Cancelled"));
            Assert.Equal("ضغط…", L10n.T("Compress…"));
            var counted = L10n.T("Converting 2 of 5");
            Assert.NotEqual("Converting 2 of 5", counted);
            Assert.Contains("2", counted);
            Assert.Contains("5", counted);
            Assert.Equal("some text nobody translated", L10n.T("some text nobody translated"));
        }
        finally { L10n.Override("en"); }
        Assert.Equal("Cancel", L10n.T("Cancel"));
    }

    [Fact]
    public void EveryTranslationSaysSomething()
    {
        var strings = Table("strings.ar.json");
        Assert.True(strings.Count > 400, $"only {strings.Count} translations were found");
        Assert.All(strings, pair => Assert.False(string.IsNullOrWhiteSpace(pair.Value), $"\"{pair.Key}\" has no Arabic"));
    }

    [Fact]
    public void EveryPatternUsesOnlyTheValuesItsEnglishHas()
    {
        static HashSet<string> Values(string text) => Regex.Matches(text, @"\{\d\}").Select(match => match.Value).ToHashSet();
        Assert.All(Table("patterns.ar.json"), pair =>
            Assert.True(Values(pair.Value).IsSubsetOf(Values(pair.Key)), $"\"{pair.Key}\" → \"{pair.Value}\" names a value the English lacks"));
    }
}
