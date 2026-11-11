using ImageMagick;
using ZXing;

namespace Adawat.Core.Tests;

public class QrTests
{
    private static string? Read(string png)
    {
        using var image = new MagickImage(png);
        var pixels = image.GetPixels().ToByteArray(PixelMapping.RGB)!;
        var source = new RGBLuminanceSource(pixels, (int)image.Width, (int)image.Height, RGBLuminanceSource.BitmapFormat.RGB24);
        return new BarcodeReaderGeneric { Options = { TryHarder = true } }.Decode(source)?.Text;
    }

    [Theory]
    [InlineData("https://example.com/adawat?tool=qr")]
    [InlineData("أدوات: حوّل أي ملف وأنت تسحبه")]
    public async Task ATextFileBecomesACodeThatScans(string text)
    {
        using var scratch = new Scratch();
        var file = scratch.File("link.txt");
        File.WriteAllText(file, text + "\n");
        var png = await TestKit.RunOne("text.qr", file);
        Assert.Equal(scratch.File("link QR.png"), png);
        Assert.Equal(text, Read(png));
    }

    [Fact]
    public void WifiCodesEscapeWhatPhonesTreatAsPunctuation()
    {
        Assert.Equal("WIFI:T:WPA;S:Home\\;Net;P:pa\\:ss;;", QrContent.Wifi("Home;Net", "pa:ss", QrContent.Security.Wpa, hidden: false));
        Assert.Equal("WIFI:T:nopass;S:Cafe;H:true;;", QrContent.Wifi("Cafe", "ignored", QrContent.Security.None, hidden: true));
    }

    [Fact]
    public async Task AnEmptyFileIsReportedInWords()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("empty.txt"), "  \n");
        await Assert.ThrowsAsync<AdawatException>(() => TestKit.Run("text.qr", scratch.File("empty.txt")));
    }
}
