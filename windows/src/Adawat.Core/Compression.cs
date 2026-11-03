using Adawat.Core.Images;
using ImageMagick;

namespace Adawat.Core;

public static class CompressPresets
{
    public static string Title(this CompressPreset preset) => preset switch
    {
        CompressPreset.Light => "Light",
        CompressPreset.Balanced => "Balanced",
        _ => "Strong",
    };

    public static string Detail(this CompressPreset preset) => preset switch
    {
        CompressPreset.Light => "Better visual quality with moderate file-size savings.",
        CompressPreset.Balanced => "Smaller files with less quality loss.",
        _ => "Smaller files with more quality loss.",
    };

    public static double ImageQuality(this CompressPreset preset) => preset switch
    {
        CompressPreset.Light => 0.85,
        CompressPreset.Balanced => 0.7,
        _ => 0.5,
    };

    /// <summary>Share of the original bitrate kept for video and audio.</summary>
    public static double MediaShare(this CompressPreset preset) => preset switch
    {
        CompressPreset.Light => 0.65,
        CompressPreset.Balanced => 0.45,
        _ => 0.3,
    };
}

/// <summary>An exact size for each file, or a share (0.01…0.99) of each file's size to remove.</summary>
public abstract record CompressTarget
{
    public sealed record Bytes(long Value) : CompressTarget;
    public sealed record Reduction(double Share) : CompressTarget;

    public long For(long original) => this switch
    {
        Bytes bytes => bytes.Value,
        Reduction reduction => (long)(original * (1 - reduction.Share)),
        _ => original,
    };
}

public sealed record CompressSettings(CompressPreset Preset = CompressPreset.Balanced, int? ImageMaxPixels = null,
                                      int? VideoMaxHeight = null, CompressTarget? Target = null)
{
    /// <summary>The defaults remembered from the last compress window, used by one-step runs.</summary>
    public static CompressSettings Saved
    {
        get
        {
            var settings = Settings.Current;
            return new(settings.CompressPreset, settings.CompressImageMaxPixels > 0 ? settings.CompressImageMaxPixels : null,
                       settings.CompressVideoMaxHeight > 0 ? settings.CompressVideoMaxHeight : null);
        }
    }
}

public static partial class Compression
{
    public static async Task<IReadOnlyList<string>> Images(IReadOnlyList<string> files, CompressSettings settings, OperationContext context)
    {
        var outputs = new List<string>();
        long before = 0, after = 0;
        var skipped = 0;
        for (var index = 0; index < files.Count; index++)
        {
            context.Report($"Compressing {index + 1} of {files.Count}");
            context.Progress((double)index / files.Count);
            var file = files[index];
            var original = ImageEngine.Size(file);
            using var image = await ImageEngine.LoadAsync(file);
            var format = ImageOps.CompressedFormat(file, image);
            var output = Output.PathFor(file, format.Ext, "compressed");
            if (settings.Target is { } target)
            {
                var data = await Task.Run(() => Fit(image, format, target.For(original), settings.ImageMaxPixels));
                await File.WriteAllBytesAsync(output, data);
            }
            else
            {
                await Task.Run(() =>
                {
                    if (settings.ImageMaxPixels is { } max && Math.Max(image.Width, image.Height) > max)
                        image.Resize(new MagickGeometry((uint)max, (uint)max));
                    ImageEngine.Save(image, format, output, settings.Preset.ImageQuality());
                });
                // Re-encoding an already tight file can grow it; keep nothing rather than a bigger copy.
                if (settings.ImageMaxPixels == null && ImageEngine.Size(output) >= original)
                {
                    File.Delete(output);
                    skipped++;
                    continue;
                }
            }
            before += original;
            after += ImageEngine.Size(output);
            outputs.Add(output);
        }
        if (outputs.Count == 0 && skipped > 0) throw new AdawatException("Already as small as this preset gets. Try Strong or a target size.");
        context.Finish(Savings("image", outputs.Count, before, after));
        return outputs;
    }

    /// <summary>The highest quality that fits <paramref name="limit"/>, shrinking the picture only when even the lowest quality is too big.</summary>
    private static byte[] Fit(MagickImage source, ImageFormat format, long limit, int? maxPixels)
    {
        if (limit < 1024) throw new AdawatException("Enter a target size of at least 1 KB.");
        var longest = (int)Math.Max(source.Width, source.Height);
        var pixels = maxPixels.HasValue ? Math.Min(maxPixels.Value, longest) : longest;
        var smallest = long.MaxValue;
        for (var round = 0; round < 8 && pixels >= 32; round++)
        {
            using var image = (MagickImage)source.Clone();
            if (pixels < longest) image.Resize(new MagickGeometry((uint)pixels, (uint)pixels));
            if (BestQuality(image, format, limit) is { } data) return data;
            smallest = Math.Min(smallest, ImageEngine.Encode(image, format, 0.05).LongLength);
            pixels = (int)(pixels * 0.8);
        }
        throw new AdawatException($"Could not reach the target size. Smallest attempt was {Format.Bytes(smallest)}.");
    }

    private static byte[]? BestQuality(MagickImage image, ImageFormat format, long limit)
    {
        var top = ImageEngine.Encode(image, format, 0.95);
        if (top.LongLength <= limit) return top;
        double low = 0.05, high = 0.95;
        byte[]? best = null;
        for (var step = 0; step < 7; step++)
        {
            var mid = (low + high) / 2;
            var data = ImageEngine.Encode(image, format, mid);
            if (data.LongLength <= limit) { best = data; low = mid; } else { high = mid; }
        }
        if (best == null)
        {
            var floor = ImageEngine.Encode(image, format, 0.05);
            if (floor.LongLength <= limit) best = floor;
        }
        return best;
    }

    internal static string Savings(string noun, int count, long before, long after)
    {
        var label = $"{count} {noun}{(count == 1 ? "" : "s")}";
        if (before <= 0) return $"Compressed {label}";
        var saved = Math.Min(99, 100 - (int)Math.Round((double)after / before * 100));
        return saved > 0 ? $"Compressed {label} · {saved}% smaller" : $"Compressed {label} · already as small as it gets";
    }
}
