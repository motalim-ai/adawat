namespace Adawat.Core.Tests;

public class SubtitleTests
{
    private const string Srt = "1\n00:00:01,000 --> 00:00:02,500\nHello there\n\n2\n00:01:03,250 --> 00:01:05,000\nSecond line\nstill the second\n";

    [Fact]
    public async Task SrtBecomesWebVtt()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("film.srt"), Srt);
        var vtt = File.ReadAllText(await TestKit.RunOne("subtitle.vtt", scratch.File("film.srt")));
        Assert.StartsWith("WEBVTT", vtt);
        Assert.Contains("00:00:01.000 --> 00:00:02.500", vtt);
        Assert.Contains("00:01:03.250 --> 00:01:05.000", vtt);
        Assert.Contains("Second line\nstill the second", vtt.Replace("\r\n", "\n"));
    }

    [Fact]
    public async Task WebVttBecomesSrtAgain()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("film.srt"), Srt);
        var vtt = await TestKit.RunOne("subtitle.vtt", scratch.File("film.srt"));
        File.Delete(scratch.File("film.srt"));
        var srt = File.ReadAllText(await TestKit.RunOne("subtitle.srt", vtt)).Replace("\r\n", "\n");
        Assert.Contains("1\n00:00:01,000 --> 00:00:02,500\nHello there", srt);
        Assert.Contains("2\n00:01:03,250 --> 00:01:05,000\nSecond line", srt);
    }

    [Fact]
    public async Task TextDropsTheTimings()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("film.srt"), Srt);
        var text = File.ReadAllText(await TestKit.RunOne("subtitle.txt", scratch.File("film.srt"))).Replace("\r\n", "\n");
        Assert.DoesNotContain("-->", text);
        Assert.Contains("Hello there", text);
        Assert.Contains("still the second", text);
    }

    [Fact]
    public async Task AFileWithoutCuesIsReportedInWords()
    {
        using var scratch = new Scratch();
        File.WriteAllText(scratch.File("empty.srt"), "nothing here\n");
        var error = await Assert.ThrowsAsync<AdawatException>(() => TestKit.Run("subtitle.vtt", scratch.File("empty.srt")));
        Assert.Contains("empty.srt", error.Message);
    }
}
