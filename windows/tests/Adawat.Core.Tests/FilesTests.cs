namespace Adawat.Core.Tests;

/// <summary>What kind a file is, and what its results are called.</summary>
public class FilesTests
{
    [Theory]
    [InlineData("photo.JPG", FileKind.Image)]
    [InlineData("photo.heic", FileKind.Image)]
    [InlineData("report.pdf", FileKind.Pdf)]
    [InlineData("clip.mkv", FileKind.Video)]
    [InlineData("voice.opus", FileKind.Audio)]
    [InlineData("letter.docx", FileKind.Document)]
    [InlineData("table.csv", FileKind.Spreadsheet)]
    [InlineData("deck.pptx", FileKind.Presentation)]
    [InlineData("film.vtt", FileKind.Subtitle)]
    [InlineData("box.tar.gz", FileKind.Archive)]
    [InlineData("data.xyz", FileKind.Other)]
    [InlineData("no extension", FileKind.Other)]
    public void KindComesFromTheExtension(string name, FileKind kind) => Assert.Equal(kind, FileKinds.Of(Path.Combine(Path.GetTempPath(), name)));

    [Fact]
    public void AFolderIsAFolderWhateverItsName()
    {
        using var scratch = new Scratch();
        var folder = Directory.CreateDirectory(scratch.File("holiday.jpg")).FullName;
        Assert.Equal(FileKind.Folder, FileKinds.Of(folder));
    }

    [Theory]
    [InlineData("a.TAR.GZ", "tgz")]
    [InlineData("a.tgz", "tgz")]
    [InlineData("Photo.JPEG", "jpeg")]
    [InlineData("archive.tar", "tar")]
    [InlineData("README", "")]
    public void ExtensionIsLowerCaseAndTarGzCountsAsOne(string name, string ext) => Assert.Equal(ext, FileKinds.Ext(name));

    [Fact]
    public void AResultNeverReplacesAFileThatIsThere()
    {
        using var scratch = new Scratch();
        var first = scratch.File("photo.png");
        Assert.Equal(first, Output.Unique(first));
        File.WriteAllText(first, "");
        Assert.Equal(scratch.File("photo 2.png"), Output.Unique(first));
        File.WriteAllText(scratch.File("photo 2.png"), "");
        Assert.Equal(scratch.File("photo 3.png"), Output.Unique(first));
    }

    [Fact]
    public void AResultIsNamedAfterItsSourceAndSavedNextToIt()
    {
        using var scratch = new Scratch();
        var source = scratch.File("holiday.jpg");
        File.WriteAllText(source, "");
        Assert.Equal(scratch.File("holiday.png"), Output.PathFor(source, "png"));
        Assert.Equal(scratch.File("holiday rotated.jpg"), Output.PathFor(source, "jpg", "rotated"));
        Assert.Equal(scratch.File("box.zip"), Output.PathFor(scratch.File("box.tar.gz"), "zip"));
    }
}
