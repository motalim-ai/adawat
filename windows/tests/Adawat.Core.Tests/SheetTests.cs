using Adawat.Core.Documents;

namespace Adawat.Core.Tests;

public class SheetTests
{
    private static string Table(Scratch scratch)
    {
        var path = scratch.File("table.csv");
        File.WriteAllText(path, "name,age,city\nAli,30,Cairo\nMona,28,\"Giza, west\"\n");
        return path;
    }

    private static List<List<string>> Cells(string path) =>
        SheetOps.Read(path)[0].Rows.Select(row => row.Select(cell => Convert.ToString(cell, System.Globalization.CultureInfo.InvariantCulture) ?? "").ToList()).ToList();

    private static readonly List<List<string>> Expected = [["name", "age", "city"], ["Ali", "30", "Cairo"], ["Mona", "28", "Giza, west"]];

    [Theory]
    [InlineData("xlsx")]
    [InlineData("ods")]
    [InlineData("tsv")]
    public async Task ATableKeepsItsCells(string ext)
    {
        using var scratch = new Scratch();
        var output = await TestKit.RunOne($"sheet.{ext}", Table(scratch));
        Assert.Equal(Expected, Cells(output));
    }

    [Fact]
    public async Task ExcelBecomesCsvAgain()
    {
        using var scratch = new Scratch();
        var excel = await TestKit.RunOne("sheet.xlsx", Table(scratch));
        File.Delete(scratch.File("table.csv"));
        var csv = await TestKit.RunOne("sheet.csv", excel);
        Assert.Equal(Expected, Cells(csv));
        Assert.Contains("\"Giza, west\"", File.ReadAllText(csv));
    }

    [Fact]
    public async Task ATableBecomesAWebPage()
    {
        using var scratch = new Scratch();
        var html = File.ReadAllText(await TestKit.RunOne("sheet.html", Table(scratch)));
        Assert.Contains("<table", html);
        Assert.Contains("Giza, west", html);
    }
}
