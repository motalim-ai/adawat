using Adawat.Core.Images;
using Adawat.Core.Pdf;
using ImageMagick;

namespace Adawat.Core.Tests;

public class ImageTests
{
    [Theory]
    [InlineData("png")]
    [InlineData("webp")]
    [InlineData("avif")]
    [InlineData("tiff")]
    [InlineData("gif")]
    [InlineData("bmp")]
    public async Task ConvertsAPhotoAndKeepsItsSize(string ext)
    {
        using var scratch = new Scratch();
        var photo = Samples.Photo(scratch.File("photo.jpg"), 640, 400);
        var output = await TestKit.RunOne($"image.{ext}", photo);
        Assert.Equal(scratch.File($"photo.{ext}"), output);
        using var image = new MagickImage(output);
        Assert.Equal((640u, 400u), (image.Width, image.Height));
    }

    [Fact]
    public async Task ConvertsAPngToJpeg()
    {
        using var scratch = new Scratch();
        var output = await TestKit.RunOne("image.jpg", Samples.Photo(scratch.File("drawing.png")));
        using var image = new MagickImage(output);
        Assert.Equal(MagickFormat.Jpeg, image.Format);
    }

    [Fact]
    public async Task AnIconIsNoLargerThan256()
    {
        using var scratch = new Scratch();
        var output = await TestKit.RunOne("image.ico", Samples.Photo(scratch.File("photo.jpg"), 640, 400));
        using var images = new MagickImageCollection(output);
        Assert.NotEmpty(images);
        Assert.All(images, image => Assert.True(image.Width <= 256 && image.Height <= 256));
    }

    [Fact]
    public async Task ConvertsSeveralPhotosAtOnce()
    {
        using var scratch = new Scratch();
        var photos = new[] { Samples.Photo(scratch.File("a.jpg")), Samples.Photo(scratch.File("b.jpg")), Samples.Photo(scratch.File("c.jpg")) };
        var outputs = await TestKit.Run("image.png", photos);
        Assert.Equal(["a.png", "b.png", "c.png"], outputs.Select(Path.GetFileName));
        Assert.All(outputs, output => Assert.True(File.Exists(output)));
    }

    [Fact]
    public async Task RotateTurnsAQuarter()
    {
        using var scratch = new Scratch();
        var output = await TestKit.RunOne("image.rotate", Samples.Photo(scratch.File("photo.jpg"), 640, 400));
        using var image = new MagickImage(output);
        Assert.Equal((400u, 640u), (image.Width, image.Height));
    }

    [Fact]
    public async Task CropWithoutItsWindowCutsASquare()
    {
        using var scratch = new Scratch();
        var output = (await ImageOps.SquareCrop([Samples.Photo(scratch.File("photo.jpg"), 640, 400)], new OperationContext()))[0];
        using var image = new MagickImage(output);
        Assert.Equal((400u, 400u), (image.Width, image.Height));
    }

    [Fact]
    public async Task PhotosBecomeAPdfWithAPageEach()
    {
        using var scratch = new Scratch();
        var photos = new[] { Samples.Photo(scratch.File("a.jpg")), Samples.Photo(scratch.File("b.png")), Samples.Photo(scratch.File("c.jpg")) };
        var output = await TestKit.RunOne("image.topdf", photos);
        Assert.Equal(3, PdfOps.PageCount(output));
    }

    [Fact]
    public async Task TheOriginalIsNeverChanged()
    {
        using var scratch = new Scratch();
        var photo = Samples.Photo(scratch.File("photo.jpg"));
        var before = File.ReadAllBytes(photo);
        await TestKit.Run("image.rotate", photo);
        await TestKit.Run("image.png", photo);
        await TestKit.Run("image.metadata", photo, Samples.Photo(scratch.File("other.jpg")));
        Assert.Equal(before, File.ReadAllBytes(photo));
    }
}
