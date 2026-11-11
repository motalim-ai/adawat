using Adawat.Core.Pdf;
using ImageMagick;

namespace Adawat.Core.Tests;

public class PdfTests
{
    [Fact]
    public async Task SplitGivesAFileForEveryPage()
    {
        using var scratch = new Scratch();
        var pdf = await Samples.Pdf(scratch, "report", 3);
        var outputs = await TestKit.Run("pdf.split", pdf);
        var pages = outputs.SelectMany(output => Directory.Exists(output) ? Directory.GetFiles(output, "*.pdf") : [output]).ToList();
        Assert.Equal(3, pages.Count);
        Assert.All(pages, page => Assert.Equal(1, PdfOps.PageCount(page)));
    }

    [Fact]
    public async Task MergeKeepsEveryPageInOrder()
    {
        using var scratch = new Scratch();
        var first = await Samples.Pdf(scratch, "first", 3);
        var second = await Samples.Pdf(scratch, "second", 2);
        var output = await TestKit.RunOne("pdf.merge", first, second);
        Assert.Equal(5, PdfOps.PageCount(output));
    }

    [Theory]
    [InlineData("png")]
    [InlineData("jpg")]
    public async Task PagesBecomePictures(string ext)
    {
        using var scratch = new Scratch();
        var pdf = await Samples.Pdf(scratch, "report", 2);
        var outputs = await TestKit.Run($"pdf.{ext}", pdf);
        var pictures = outputs.SelectMany(output => Directory.Exists(output) ? Directory.GetFiles(output) : [output]).ToList();
        Assert.Equal(2, pictures.Count);
        Assert.All(pictures, picture =>
        {
            Assert.EndsWith($".{ext}", picture);
            using var image = new MagickImage(picture);
            Assert.True(image.Width > 100 && image.Height > 100);
        });
    }

    [Fact]
    public async Task RemovingMetadataKeepsThePages()
    {
        using var scratch = new Scratch();
        var pdf = await Samples.Pdf(scratch, "report", 2);
        var output = await TestKit.RunOne("pdf.metadata", pdf);
        Assert.NotEqual(pdf, output);
        Assert.Equal(2, PdfOps.PageCount(output));
    }

    /// <summary>Saudi Arabia's region setting brings a Hijri calendar, which a PDF's dates must not be written in.</summary>
    [Fact]
    public async Task PdfsSaveUnderAHijriCalendar()
    {
        using var scratch = new Scratch();
        using var region = new Region("ar-SA");
        var pdf = await Samples.Pdf(scratch, "report", 2);
        Assert.Equal(2, PdfOps.PageCount(await TestKit.RunOne("pdf.metadata", pdf)));
        Assert.Equal(4, PdfOps.PageCount(await TestKit.RunOne("pdf.merge", pdf, pdf)));
        var pages = await TestKit.Run("pdf.split", pdf);
        Assert.NotEmpty(pages);
    }

    [Fact]
    public async Task ADamagedPdfIsReportedInWords()
    {
        using var scratch = new Scratch();
        var broken = scratch.File("broken.pdf");
        File.WriteAllText(broken, "this is not a PDF");
        var error = await Assert.ThrowsAsync<AdawatException>(() => TestKit.Run("pdf.split", broken));
        Assert.Contains("broken.pdf", error.Message);
    }
}
