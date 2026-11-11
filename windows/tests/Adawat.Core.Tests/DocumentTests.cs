using System.IO.Compression;
using Adawat.Core.Documents;

namespace Adawat.Core.Tests;

public class DocumentTests
{
    private const string Note = "# Travel notes\n\nHello **world**, this is a note.\n\n- one\n- two\n";

    private static string Markdown(Scratch scratch)
    {
        var path = scratch.File("note.md");
        File.WriteAllText(path, Note);
        return path;
    }

    [Fact]
    public async Task MarkdownBecomesWordAndBack()
    {
        using var scratch = new Scratch();
        var word = await TestKit.RunOne("doc.docx", Markdown(scratch));
        Assert.Equal(scratch.File("note.docx"), word);
        var back = await TestKit.RunOne("doc.md", word);
        var text = File.ReadAllText(back);
        Assert.Contains("# Travel notes", text);
        Assert.Contains("**world**", text);
        Assert.Contains("one", text);
    }

    [Fact]
    public async Task MarkdownBecomesHtmlWithItsHeading()
    {
        using var scratch = new Scratch();
        var html = File.ReadAllText(await TestKit.RunOne("doc.html", Markdown(scratch)));
        Assert.Contains("<h1", html);
        Assert.Contains("Travel notes", html);
        Assert.Contains("<li", html);
    }

    [Fact]
    public async Task MarkdownBecomesPlainText()
    {
        using var scratch = new Scratch();
        var text = File.ReadAllText(await TestKit.RunOne("doc.txt", Markdown(scratch)));
        Assert.Contains("Travel notes", text);
        Assert.Contains("Hello world, this is a note.", text);
        Assert.DoesNotContain("**", text);
    }

    [Theory]
    [InlineData("epub", "mimetype")]
    [InlineData("odt", "content.xml")]
    public async Task MarkdownBecomesAPackagedDocument(string ext, string entry)
    {
        using var scratch = new Scratch();
        var output = await TestKit.RunOne($"doc.{ext}", Markdown(scratch));
        using var zip = ZipFile.OpenRead(output);
        Assert.Contains(zip.Entries, e => e.FullName == entry);
        var loaded = await DocumentOps.Load(output);
        Assert.NotEmpty(loaded.Blocks);
    }

    [Fact]
    public async Task ArabicTextSurvivesWord()
    {
        using var scratch = new Scratch();
        var note = scratch.File("arabic.md");
        File.WriteAllText(note, "# عنوان\n\nمرحبا بالعالم.\n");
        var word = await TestKit.RunOne("doc.docx", note);
        var text = File.ReadAllText(await TestKit.RunOne("doc.txt", word));
        Assert.Contains("عنوان", text);
        Assert.Contains("مرحبا بالعالم.", text);
    }
}
