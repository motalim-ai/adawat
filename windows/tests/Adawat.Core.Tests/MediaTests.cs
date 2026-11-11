using Adawat.Core.Media;

namespace Adawat.Core.Tests;

/// <summary>Video and audio, through ffmpeg. Skipped where ffmpeg is not installed.</summary>
public class MediaTests
{
    private static void Near(double expected, double actual, double tolerance = 0.35) =>
        Assert.True(Math.Abs(expected - actual) <= tolerance, $"expected about {expected} s, got {actual} s");

    [Theory]
    [InlineData("mp3", "mp3")]
    [InlineData("m4a", "aac")]
    public async Task AVideoGivesItsSoundAlone(string ext, string codec)
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var output = await TestKit.RunOne($"media.{ext}", await Samples.Clip(scratch.File("clip.mp4")));
        var info = await MediaProbe.Info(output);
        Assert.False(info.HasVideo);
        Assert.Equal(codec, info.AudioCodec);
        Near(2, info.Duration);
    }

    [Theory]
    [InlineData("mov")]
    [InlineData("mkv")]
    [InlineData("webm")]
    public async Task AVideoChangesContainerAndKeepsPictureAndSound(string ext)
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var output = await TestKit.RunOne($"media.{ext}", await Samples.Clip(scratch.File("clip.mp4")));
        var info = await MediaProbe.Info(output);
        Assert.True(info.HasVideo && info.HasAudio);
        Assert.Equal((320, 240), (info.Width, info.Height));
        Near(2, info.Duration);
    }

    [Fact]
    public async Task AVideoBecomesAGif()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var output = await TestKit.RunOne("media.gif", await Samples.Clip(scratch.File("clip.mp4"), 1));
        using var frames = new ImageMagick.MagickImageCollection(output);
        Assert.True(frames.Count > 1);
    }

    [Fact]
    public async Task MuteDropsTheSoundOnly()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var info = await MediaProbe.Info(await TestKit.RunOne("video.mute", await Samples.Clip(scratch.File("clip.mp4"))));
        Assert.True(info.HasVideo);
        Assert.False(info.HasAudio);
    }

    [Fact]
    public async Task RotateTurnsAQuarter()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var info = await MediaProbe.Info(await TestKit.RunOne("video.rotate", await Samples.Clip(scratch.File("clip.mp4"))));
        Assert.Equal((240, 320), (info.Width, info.Height));
    }

    [Fact]
    public async Task JoinPlaysOneAfterTheOther()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var first = await Samples.Clip(scratch.File("first.mp4"), 2);
        var second = await Samples.Clip(scratch.File("second.mp4"), 1);
        var info = await MediaProbe.Info(await TestKit.RunOne("video.join", first, second));
        Assert.True(info.HasVideo && info.HasAudio);
        Near(3, info.Duration);
    }

    [Fact]
    public async Task TrimKeepsTheChosenPart()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var output = await MediaOps.Trim(await Samples.Clip(scratch.File("clip.mp4"), 3), 0.5, 2, trimSilence: false, new OperationContext());
        Near(1.5, (await MediaProbe.Info(output)).Duration);
    }

    [Theory]
    [InlineData("flac", "flac")]
    [InlineData("ogg", "vorbis")]
    [InlineData("opus", "opus")]
    [InlineData("m4a", "aac")]
    public async Task AudioConverts(string ext, string codec)
    {
        if (ext == "ogg") TestKit.NeedEncoder("libvorbis"); else TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var info = await MediaProbe.Info(await TestKit.RunOne($"media.{ext}", await Samples.Tone(scratch.File("tone.wav"))));
        Assert.Equal(codec, info.AudioCodec);
        Near(2, info.Duration);
    }

    [Fact]
    public async Task ToMonoLeavesOneChannel()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var stereo = await Samples.Tone(scratch.File("stereo.wav"), channels: 2);
        Assert.Equal(2, (await MediaProbe.Info(stereo)).AudioChannels);
        var outputs = await TestKit.Run("audio.mono", stereo, await Samples.Tone(scratch.File("tone.wav")));
        Assert.Equal(2, outputs.Count);
        Assert.All(outputs, output => Assert.Equal(1, MediaProbe.Info(output).GetAwaiter().GetResult().AudioChannels));
    }

    [Fact]
    public async Task NormalizeKeepsTheLength()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var outputs = await TestKit.Run("audio.normalize", await Samples.Tone(scratch.File("a.wav")), await Samples.Tone(scratch.File("b.wav"), 1));
        Assert.Equal(2, outputs.Count);
        Near(2, (await MediaProbe.Info(outputs[0])).Duration);
    }
}
