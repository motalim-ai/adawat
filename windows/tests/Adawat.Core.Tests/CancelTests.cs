using System.Diagnostics;
using Adawat.Core.Media;

namespace Adawat.Core.Tests;

/// <summary>The toast's Cancel: tools stop, loops stop between files, and nothing half-written stays behind.</summary>
public class CancelTests
{
    /// <summary>Runs a choice and cancels it the first time <paramref name="when"/> is true of what it reports.</summary>
    private static async Task<IReadOnlyList<string>> RunAndCancel(string id, IReadOnlyList<string> files, Func<string?, double?, bool> when)
    {
        using var cancel = new CancellationTokenSource();
        var context = new OperationContext(text => { if (when(text, null)) cancel.Cancel(); }, fraction => { if (when(null, fraction)) cancel.Cancel(); }, cancel.Token);
        var operation = Catalog.Find(id, files) ?? throw new InvalidOperationException($"no {id}");
        return await Task.Run(() => context.Run(operation.Run, files));
    }

    [Fact]
    public async Task ABatchStopsBetweenFilesAndKeepsWhatItFinished()
    {
        using var scratch = new Scratch();
        var photos = Enumerable.Range(1, 6).Select(n => Samples.Photo(scratch.File($"photo{n}.jpg"))).ToList();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => RunAndCancel("image.png", photos, (text, _) => text == "Converting 3 of 6"));
        Assert.Equal(["photo1.png", "photo2.png"], scratch.Names().Where(name => name.EndsWith(".png")));
    }

    [Fact]
    public async Task ACancelledPackLeavesNoArchive()
    {
        using var scratch = new Scratch();
        var folder = Directory.CreateDirectory(scratch.File("trip")).FullName;
        for (var n = 0; n < 20; n++) File.WriteAllText(Path.Combine(folder, $"{n}.txt"), "text");
        foreach (var format in new[] { "zip", "tar", "tgz" })
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => RunAndCancel($"archive.{format}", [folder], (text, _) => text != null));
        }
        Assert.Equal(["trip/"], scratch.Names());
    }

    [Fact]
    public async Task ACancelledExtractLeavesNoFolder()
    {
        using var scratch = new Scratch();
        var folder = Directory.CreateDirectory(scratch.File("trip")).FullName;
        for (var n = 0; n < 20; n++) File.WriteAllText(Path.Combine(folder, $"{n}.txt"), "text");
        var zip = await TestKit.RunOne("archive.zip", folder);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => RunAndCancel("archive.extract", [zip], (_, fraction) => fraction > 0.2));
        Assert.Equal(["trip.zip", "trip/"], scratch.Names());
    }

    [Fact]
    public async Task ACancelledConversionStopsFfmpegAndRemovesItsFile()
    {
        TestKit.NeedFfmpeg();
        using var scratch = new Scratch();
        var clip = await Samples.Clip(scratch.File("long.mp4"), 40);
        var watch = Stopwatch.StartNew();
        // The first progress line means ffmpeg is running and has started the file.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => RunAndCancel("media.webm", [clip], (_, fraction) => fraction != null));
        Assert.Equal(["long.mp4"], scratch.Names());
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(20), $"cancelling took {watch.Elapsed.TotalSeconds:0.0} s");
    }

    [Fact]
    public async Task AToolStartedWithoutATokenStopsWithTheOperation()
    {
        var (tool, arguments) = OperatingSystem.IsWindows() ? ("ping", new[] { "-n", "60", "127.0.0.1" }) : ("sleep", new[] { "60" });
        using var cancel = new CancellationTokenSource();
        var context = new OperationContext(cancellation: cancel.Token);
        var watch = Stopwatch.StartNew();
        var work = Task.Run(() => context.Run(async (_, _) =>
        {
            await ProcessRunner.Run(ProcessRunner.Require(tool), arguments);
            return [];
        }, []));
        await Task.Delay(400);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"the tool ran on for {watch.Elapsed.TotalSeconds:0.0} s");
    }

    [Fact]
    public async Task AnOperationCancelledBeforeItStartsDoesNothing()
    {
        using var scratch = new Scratch();
        var photo = Samples.Photo(scratch.File("photo.jpg"));
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        var context = new OperationContext(cancellation: cancel.Token);
        var operation = Catalog.Find("image.png", [photo])!;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Task.Run(() => context.Run(operation.Run, [photo])));
        Assert.Equal(["photo.jpg"], scratch.Names());
    }

    [Fact]
    public void ProgressFromAToolsOwnThreadNeverThrows()
    {
        using var cancel = new CancellationTokenSource();
        var context = new OperationContext(cancellation: cancel.Token);
        var report = context.ProgressFor(0, 1);
        cancel.Cancel();
        report(0.5);
        Assert.Throws<OperationCanceledException>(() => context.Progress(0.5));
        Assert.Throws<OperationCanceledException>(() => context.ProgressFor(0, 1));
    }
}
