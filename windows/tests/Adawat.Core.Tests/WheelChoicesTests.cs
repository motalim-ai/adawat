using System.Text.Json;

namespace Adawat.Core.Tests;

/// <summary>The wheel offers what Tests/wheel-choices.json says, in that order. The Mac app's tests read the same file.</summary>
public class WheelChoicesTests
{
    /// <summary>The plain net10.0 core is the Linux one, also when the tests run on a Mac.</summary>
    private static string Platform => OperatingSystem.IsWindows() ? "windows" : "linux";

    private static readonly JsonElement Spec = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "wheel-choices.json"))).RootElement;

    public static TheoryData<string> Cases()
    {
        var data = new TheoryData<string>();
        foreach (var item in Spec.GetProperty("cases").EnumerateArray()) data.Add(item.GetProperty("name").GetString()!);
        return data;
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void Offers(string name)
    {
        var item = Spec.GetProperty("cases").EnumerateArray().First(c => c.GetProperty("name").GetString() == name);
        using var scratch = new Scratch();
        var files = item.GetProperty("files").EnumerateArray().Select(f => f.GetString()!).Select(file =>
        {
            var path = scratch.File(file.TrimEnd('/'));
            if (file.EndsWith('/')) Directory.CreateDirectory(path); else File.WriteAllText(path, "");
            return path;
        }).ToList();

        Check("Convert", item.GetProperty("convert"), Catalog.For(WheelMode.Convert, files));
        Check("Tools", item.GetProperty("tools"), Catalog.For(WheelMode.Tools, files));
        Check("Actions", Spec.GetProperty("actions"), Catalog.For(WheelMode.Actions, files));
    }

    private static void Check(string wheel, JsonElement expected, IReadOnlyList<AdawatOperation> offered)
    {
        var required = new List<string>();
        var optional = new HashSet<string>();
        foreach (var entry in expected.EnumerateArray())
        {
            if (entry.ValueKind == JsonValueKind.String) { required.Add(entry.GetString()!); continue; }
            if (entry.TryGetProperty("only", out var only) && !only.EnumerateArray().Any(p => p.GetString() == Platform)) continue;
            if (entry.TryGetProperty("not", out var not) && not.EnumerateArray().Any(p => p.GetString() == Platform)) continue;
            var id = entry.GetProperty("id").GetString()!;
            if (entry.TryGetProperty("optional", out var flag) && flag.GetBoolean()) optional.Add(id); else required.Add(id);
        }
        // Choices that depend on what is installed may be there or not; everything else has to match, in petal order.
        var actual = offered.Select(operation => operation.Id).Where(id => !optional.Contains(id)).ToList();
        Assert.True(required.SequenceEqual(actual), $"{wheel} wheel on {Platform}\n  expected: {string.Join(" ", required)}\n  offered:  {string.Join(" ", actual)}");
        Assert.Equal(offered.Count, offered.Select(operation => operation.Id).Distinct().Count());
    }
}
