using System.IO.Compression;
using System.Text.Json;
using Adawat.Core;
using Adawat.Core.Documents;
using Xunit;

namespace Adawat.Core.Tests;

public sealed class SafetyTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("adawat-test").FullName;

    public SafetyTests() => Settings.Current.OutputLocation = OutputLocation.NextToOriginal;

    public void Dispose() => Directory.Delete(_folder, true);

    [Fact]
    public void ResultsNeverReplaceAnExistingFile()
    {
        var photo = Path.Combine(_folder, "photo.jpg");
        File.WriteAllText(photo, "original");
        File.WriteAllText(Path.Combine(_folder, "photo.png"), "earlier result");

        var output = Output.PathFor(photo, "png");

        Assert.Equal(Path.Combine(_folder, "photo 2.png"), output);
        Assert.Equal(Path.Combine(_folder, "photo 2.jpg"), Output.Unique(photo));
    }

    [Fact]
    public async Task ArchivesCannotWriteOutsideTheirFolder()
    {
        var zip = Path.Combine(_folder, "evil.zip");
        using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
        {
            using (var writer = new StreamWriter(archive.CreateEntry("../escaped.txt").Open())) writer.Write("x");
            using (var writer = new StreamWriter(archive.CreateEntry("ok.txt").Open())) writer.Write("x");
        }

        await Assert.ThrowsAnyAsync<Exception>(() => ArchiveOps.Extract([zip], new OperationContext()));

        Assert.False(File.Exists(Path.Combine(Path.GetDirectoryName(_folder)!, "escaped.txt")));
    }

    [Fact]
    public void UpdatesNeedANewerVersionAndAChecksum()
    {
        string Release(string tag, bool digest) =>
            "{\"tag_name\":\"" + tag + "\",\"body\":\"notes\",\"assets\":[{\"name\":\"app.exe\",\"browser_download_url\":\"https://example.com/app.exe\""
            + (digest ? ",\"digest\":\"sha256:ab12\"" : "") + "}]}";
        Release? Parse(string json) => Updates.Parse(JsonDocument.Parse(json).RootElement, "app.exe");

        Assert.Null(Parse(Release($"v{Updates.Current}", digest: true)));
        Assert.Null(Parse(Release("v99.0.0", digest: false)));
        var newer = Parse(Release("v99.0.0", digest: true));
        Assert.NotNull(newer);
        Assert.Equal("ab12", newer.Sha256);
    }

    [Fact]
    public async Task ACorruptedUpdateIsDeleted()
    {
        // A local server stands in for GitHub, so the test needs no network.
        using var server = new System.Net.HttpListener();
        var port = Random.Shared.Next(20000, 60000);
        server.Prefixes.Add($"http://127.0.0.1:{port}/");
        server.Start();
        _ = Task.Run(async () =>
        {
            var request = await server.GetContextAsync();
            await request.Response.OutputStream.WriteAsync("hello"u8.ToArray());
            request.Response.Close();
        });
        var release = new Release(new(99, 0, 0), "", "app.exe", new Uri($"http://127.0.0.1:{port}/app.exe"), new string('0', 64));
        var path = Path.Combine(_folder, "app.exe");

        var error = await Assert.ThrowsAsync<AdawatException>(() => Updates.Download(release, path));

        Assert.Contains("did not download correctly", error.Message);
        Assert.Empty(Directory.GetFiles(_folder));
    }

    [Fact]
    public void SlideLinesFollowTheFontsHeight()
    {
        var odp = Path.Combine(_folder, "deck.odp");
        using (var archive = ZipFile.Open(odp, ZipArchiveMode.Create))
        using (var writer = new StreamWriter(archive.CreateEntry("content.xml").Open()))
            writer.Write("""<p style:font-independent-line-spacing="true"/>""");

        Office.UseFontLineHeights(odp);

        using var result = ZipFile.OpenRead(odp);
        using var reader = new StreamReader(result.GetEntry("content.xml")!.Open());
        Assert.Equal("""<p style:font-independent-line-spacing="false"/>""", reader.ReadToEnd());
    }

    [Fact]
    public async Task CompressKeepsOnlyThePixelsThePageShows()
    {
        var photo = Path.Combine(_folder, "photo.jpg");
        using (var noise = new ImageMagick.MagickImage("plasma:", 3000, 2000)) noise.Write(photo);
        var pdf = Path.Combine(_folder, "small photo.pdf");
        using (var document = new PdfSharp.Pdf.PdfDocument())
        {
            using var graphics = PdfSharp.Drawing.XGraphics.FromPdfPage(document.AddPage());
            using var image = PdfSharp.Drawing.XImage.FromFile(photo);
            graphics.DrawImage(image, 72, 72, 360, 240); // 5 x 3.3 inches: 750 pixels wide at 150 dpi
            graphics.Dispose();
            document.Save(pdf);
        }
        Settings.Current.CompressPreset = CompressPreset.Balanced;

        var output = (await Pdf.PdfOps.Compress([pdf], new OperationContext())).Single();

        using var result = PdfSharp.Pdf.IO.PdfReader.Open(output, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var resized = result.Pages[0].Resources.Elements.GetDictionary("/XObject")!.Elements.Values
            .Select(item => (PdfSharp.Pdf.PdfDictionary)((PdfSharp.Pdf.Advanced.PdfReference)item).Value).Single();
        // Not the 1800 pixels the preset allows a picture of unknown size, and not below the floor that keeps logos sharp.
        Assert.Equal(800, resized.Elements.GetInteger("/Width"));
    }
}
