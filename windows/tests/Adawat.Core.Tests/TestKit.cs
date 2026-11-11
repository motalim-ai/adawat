using System.Runtime.CompilerServices;
using Adawat.Core.Images;
using Adawat.Core.Media;
using ImageMagick;

namespace Adawat.Core.Tests;

/// <summary>A folder of its own for each test, removed afterwards. Results land in it, next to the originals.</summary>
public sealed class Scratch : IDisposable
{
    public string Folder { get; } = Path.Combine(Path.GetTempPath(), "adawat-tests", Guid.NewGuid().ToString("N"));

    public Scratch() => Directory.CreateDirectory(Folder);

    public string File(string name) => Path.Combine(Folder, name);

    /// <summary>The names in the folder, sorted, folders with a trailing slash.</summary>
    public IReadOnlyList<string> Names() => Directory.GetFileSystemEntries(Folder)
        .Select(path => Path.GetFileName(path) + (Directory.Exists(path) ? "/" : "")).OrderBy(name => name, StringComparer.Ordinal).ToList();

    public void Dispose()
    {
        try { Directory.Delete(Folder, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

public static class TestKit
{
    /// <summary>Tests read English messages and write next to the original, whatever this machine's settings say.</summary>
    [ModuleInitializer]
    public static void Setup()
    {
        Settings.Current.OutputLocation = OutputLocation.NextToOriginal;
        L10n.Override("en");
    }

    /// <summary>Runs a wheel choice by its id, as a drop on its petal would.</summary>
    public static async Task<IReadOnlyList<string>> Run(string id, params string[] files)
    {
        var operation = Catalog.Find(id, files) ?? throw new InvalidOperationException($"The wheel has no {id} for {string.Join(", ", files.Select(Path.GetFileName))}");
        var context = new OperationContext();
        return await context.Run(operation.Run, files);
    }

    /// <summary>The single file a choice made.</summary>
    public static async Task<string> RunOne(string id, params string[] files)
    {
        var outputs = await Run(id, files);
        Assert.Single(outputs);
        Assert.True(File.Exists(outputs[0]) || Directory.Exists(outputs[0]), $"{id} reported {outputs[0]}, which is not there");
        return outputs[0];
    }

    /// <summary>Media tests need ffmpeg. Without it they are skipped, or fail where ADAWAT_TESTS_NEED_TOOLS=1 says it must be there.</summary>
    public static void NeedFfmpeg()
    {
        if (ProcessRunner.Find("ffmpeg") != null) return;
        if (Environment.GetEnvironmentVariable("ADAWAT_TESTS_NEED_TOOLS") == "1") Assert.Fail("ffmpeg was not found, and ADAWAT_TESTS_NEED_TOOLS=1 says it must be");
        Assert.Skip("ffmpeg is not installed");
    }

    /// <summary>The same for an encoder some builds of ffmpeg leave out.</summary>
    public static void NeedEncoder(string name)
    {
        NeedFfmpeg();
        if (FFmpeg.Encoders.Contains(name)) return;
        if (Environment.GetEnvironmentVariable("ADAWAT_TESTS_NEED_TOOLS") == "1") Assert.Fail($"this ffmpeg has no {name}, and ADAWAT_TESTS_NEED_TOOLS=1 says it must");
        Assert.Skip($"this ffmpeg has no {name}");
    }
}

/// <summary>Runs what follows as on a system set to another region; the setting follows the test through its awaits.</summary>
public sealed class Region : IDisposable
{
    private readonly System.Globalization.CultureInfo _before = System.Globalization.CultureInfo.CurrentCulture;

    public Region(string name) => System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo(name);

    public void Dispose() => System.Globalization.CultureInfo.CurrentCulture = _before;
}

/// <summary>Sample files made on the spot, so the repository carries no binaries.</summary>
public static class Samples
{
    /// <summary>A photo: a gradient with a block of colour, so rotations and crops can be told apart.</summary>
    public static string Photo(string path, int width = 640, int height = 400)
    {
        using var image = new MagickImage($"gradient:#2255cc-#ffcc33", (uint)width, (uint)height);
        using var block = new MagickImage(MagickColors.Crimson, (uint)(width / 4), (uint)(height / 4));
        image.Composite(block, 10, 10, CompositeOperator.Over);
        image.Write(path);
        return path;
    }

    /// <summary>A short video with a tone: 320×240, 15 frames a second.</summary>
    public static async Task<string> Clip(string path, double seconds = 2)
    {
        var length = FFmpeg.Seconds(seconds);
        await FFmpeg.Run(["-f", "lavfi", "-i", $"testsrc2=duration={length}:size=320x240:rate=15", "-f", "lavfi", "-i", $"sine=frequency=440:duration={length}",
                          .. FFmpeg.H264, "-c:a", FFmpeg.Aac, "-shortest", path], seconds, null);
        return path;
    }

    /// <summary>A tone, in the format of the path's extension.</summary>
    public static async Task<string> Tone(string path, double seconds = 2, int channels = 1)
    {
        await FFmpeg.Run(["-f", "lavfi", "-i", $"sine=frequency=440:duration={FFmpeg.Seconds(seconds)}", "-ac", channels.ToString(), path], seconds, null);
        return path;
    }

    /// <summary>A PDF with one page per photo.</summary>
    public static async Task<string> Pdf(Scratch scratch, string name, int pages)
    {
        var photos = Enumerable.Range(1, pages).Select(n => Photo(scratch.File($"{name}-page{n}.png"), 300 + n * 20, 400)).ToArray();
        var made = (await ImageOps.MakePdf(photos, new OperationContext()))[0];
        var path = scratch.File($"{name}.pdf");
        File.Move(made, path);
        foreach (var photo in photos) File.Delete(photo);
        return path;
    }
}
