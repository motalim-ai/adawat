using System.Globalization;
using System.Text.Json;

namespace Adawat.Core.Media;

/// <summary>What a media file contains, read with ffprobe.</summary>
public sealed record MediaInfo
{
    public double Duration { get; init; }
    public string? VideoCodec { get; init; }
    public string? AudioCodec { get; init; }
    /// <summary>Sample size of PCM audio, so lossless conversions keep 24-bit sources at 24 bits.</summary>
    public int AudioBits { get; init; }
    public int AudioChannels { get; init; }
    /// <summary>10/12-bit or HLG/PQ video, which must not be squeezed into 8-bit H.264.</summary>
    public bool IsHighDepth { get; init; }
    /// <summary>Frame size as shown, after any rotation tag.</summary>
    public int Width { get; init; }
    public int Height { get; init; }
    public double FrameRate { get; init; }
    public long FileSize { get; init; }

    public bool HasVideo => VideoCodec != null;
    public bool HasAudio => AudioCodec != null;
    /// <summary>Average bits per second of the whole file.</summary>
    public double Bitrate => Duration > 0 ? FileSize * 8 / Duration : 0;
}

public static class MediaProbe
{
    public static async Task<MediaInfo> Info(string path)
    {
        var size = File.Exists(path) ? new FileInfo(path).Length : 0;
        var ffprobe = ProcessRunner.Find("ffprobe");
        if (ffprobe == null) return await FromReport(path, size);
        var result = await ProcessRunner.Run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]);
        if (result.ExitCode != 0) return new MediaInfo { FileSize = size };
        using var json = JsonDocument.Parse(result.Output);
        var root = json.RootElement;
        double duration = 0;
        if (root.TryGetProperty("format", out var format) && format.TryGetProperty("duration", out var d))
            double.TryParse(d.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
        string? video = null, audio = null;
        int width = 0, height = 0, bits = 0, channels = 0;
        double rate = 0;
        var deep = false;
        if (root.TryGetProperty("streams", out var streams))
        {
            foreach (var stream in streams.EnumerateArray())
            {
                var type = stream.GetProperty("codec_type").GetString();
                var codec = stream.TryGetProperty("codec_name", out var c) ? c.GetString() : null;
                var attached = stream.TryGetProperty("disposition", out var disposition) && disposition.TryGetProperty("attached_pic", out var pic) && pic.GetInt32() == 1;
                if (type == "video" && video == null && !attached)
                {
                    video = codec;
                    width = stream.TryGetProperty("width", out var w) ? w.GetInt32() : 0;
                    height = stream.TryGetProperty("height", out var h) ? h.GetInt32() : 0;
                    var pix = stream.TryGetProperty("pix_fmt", out var p) ? p.GetString() ?? "" : "";
                    var transfer = stream.TryGetProperty("color_transfer", out var t) ? t.GetString() ?? "" : "";
                    deep = pix.Contains("10") || pix.Contains("12") || transfer is "smpte2084" or "arib-std-b67" || codec == "prores";
                    if (stream.TryGetProperty("avg_frame_rate", out var fr)) rate = Fraction(fr.GetString());
                    if (Rotation(stream) is 90 or 270 or -90 or -270) (width, height) = (height, width);
                    if (duration <= 0 && stream.TryGetProperty("duration", out var sd))
                        double.TryParse(sd.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
                }
                else if (type == "audio" && audio == null)
                {
                    audio = codec != null && codec.StartsWith("pcm_") ? "pcm" : codec;
                    if (codec != null && codec.StartsWith("pcm_")) bits = int.TryParse(new string(codec.Where(char.IsDigit).ToArray()), out var b) ? b : 16;
                    else if (stream.TryGetProperty("bits_per_raw_sample", out var raw) && int.TryParse(raw.GetString(), out var r)) bits = r;
                    channels = stream.TryGetProperty("channels", out var ch) ? ch.GetInt32() : 2;
                }
            }
        }
        return new MediaInfo
        {
            Duration = duration, VideoCodec = video, AudioCodec = audio, AudioBits = bits, AudioChannels = channels,
            IsHighDepth = deep, Width = width, Height = height, FrameRate = rate, FileSize = size,
        };
    }

    /// <summary>Without ffprobe: parses the "Duration:" and "Stream #0:0: Video: h264 …" lines ffmpeg prints for its input.</summary>
    private static async Task<MediaInfo> FromReport(string path, long size)
    {
        if (ProcessRunner.Find("ffmpeg") == null) return new MediaInfo { FileSize = size };
        var report = await FFmpeg.Report(["-i", path]);
        double duration = 0;
        var d = System.Text.RegularExpressions.Regex.Match(report, @"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)");
        if (d.Success) duration = int.Parse(d.Groups[1].Value) * 3600 + int.Parse(d.Groups[2].Value) * 60 + double.Parse(d.Groups[3].Value, CultureInfo.InvariantCulture);
        string? video = null, audio = null;
        int width = 0, height = 0, bits = 0, channels = 0, rotation = 0;
        double rate = 0;
        var deep = false;
        var r = System.Text.RegularExpressions.Regex.Match(report, @"(?:displaymatrix: rotation of|rotate\s*:)\s*(-?\d+(?:\.\d+)?)");
        if (r.Success) rotation = (int)Math.Round(double.Parse(r.Groups[1].Value, CultureInfo.InvariantCulture));
        foreach (var line in report.Split('\n').Where(l => l.Contains("Stream #")))
        {
            if (video == null && System.Text.RegularExpressions.Regex.Match(line, @"Video: (\w+)") is { Success: true } v && !line.Contains("attached pic"))
            {
                video = v.Groups[1].Value;
                deep = line.Contains("p10") || line.Contains("p12") || line.Contains("arib-std-b67") || line.Contains("smpte2084") || video == "prores";
                if (System.Text.RegularExpressions.Regex.Match(line, @", (\d{2,5})x(\d{2,5})") is { Success: true } s) { width = int.Parse(s.Groups[1].Value); height = int.Parse(s.Groups[2].Value); }
                if (System.Text.RegularExpressions.Regex.Match(line, @", (\d+(?:\.\d+)?) fps") is { Success: true } f) rate = double.Parse(f.Groups[1].Value, CultureInfo.InvariantCulture);
            }
            else if (audio == null && System.Text.RegularExpressions.Regex.Match(line, @"Audio: (\w+)") is { Success: true } a)
            {
                var codec = a.Groups[1].Value;
                if (codec.StartsWith("pcm_")) { bits = int.TryParse(new string(codec.Where(char.IsDigit).ToArray()), out var b) ? b : 16; codec = "pcm"; }
                else if (line.Contains("s32") || line.Contains("(24 bit)")) bits = 24;
                audio = codec;
                channels = line.Contains("mono") ? 1 : line.Contains("5.1") ? 6 : 2;
            }
        }
        if (rotation is 90 or -90 or 270 or -270) (width, height) = (height, width);
        return new MediaInfo
        {
            Duration = duration, VideoCodec = video, AudioCodec = audio, AudioBits = bits, AudioChannels = channels,
            IsHighDepth = deep, Width = width, Height = height, FrameRate = rate, FileSize = size,
        };
    }

    private static int Rotation(JsonElement stream)
    {
        if (stream.TryGetProperty("side_data_list", out var list))
        {
            foreach (var item in list.EnumerateArray())
            {
                if (item.TryGetProperty("rotation", out var rotation)) return rotation.GetInt32();
            }
        }
        if (stream.TryGetProperty("tags", out var tags) && tags.TryGetProperty("rotate", out var rotate) && int.TryParse(rotate.GetString(), out var value))
            return value;
        return 0;
    }

    private static double Fraction(string? text)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        var parts = text.Split('/');
        if (parts.Length == 2 && double.TryParse(parts[0], CultureInfo.InvariantCulture, out var n) && double.TryParse(parts[1], CultureInfo.InvariantCulture, out var m) && m > 0)
            return n / m;
        return double.TryParse(text, CultureInfo.InvariantCulture, out var v) ? v : 0;
    }
}

/// <summary>Runs ffmpeg with progress. Software encoders throughout (x264, x265, VP9, Opus…), so results are the same on
/// every PC, ARM or Intel, virtual or not.</summary>
public static class FFmpeg
{
    private static readonly string[] Prefix = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"];

    public static string Aac => "aac";

    private static HashSet<string>? _encoders;

    /// <summary>The encoders this ffmpeg build has, read once.</summary>
    public static HashSet<string> Encoders
    {
        get
        {
            if (_encoders != null) return _encoders;
            var set = new HashSet<string>();
            if (ProcessRunner.Find("ffmpeg") is { } ffmpeg)
            {
                var result = Task.Run(() => ProcessRunner.Run(ffmpeg, ["-hide_banner", "-encoders"])).GetAwaiter().GetResult();
                foreach (var line in result.Output.Split('\n'))
                {
                    var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2 && parts[0].Length == 6) set.Add(parts[1]);
                }
            }
            return _encoders = set;
        }
    }

    /// <summary>Video for WebM: VP9 where the build has it, otherwise AV1 (which WebM also carries, and every current browser plays).</summary>
    public static string[] WebMVideo(int crf = 33) => Encoders.Contains("libvpx-vp9")
        ? ["-c:v", "libvpx-vp9", "-crf", crf.ToString(), "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
        : ["-c:v", "libsvtav1", "-crf", (crf + 2).ToString(), "-preset", "8", "-pix_fmt", "yuv420p"];

    /// <summary>x264/x265 quality for each setting: lower CRF is better.</summary>
    public static int Crf(bool hevc) => Settings.Current.VideoQuality switch
    {
        VideoQuality.High => hevc ? 20 : 19,
        VideoQuality.Balanced => hevc ? 24 : 22,
        _ => hevc ? 28 : 26,
    };

    /// <summary>H.264 with x264 where the build has it. Fedora's ffmpeg-free has no x264 but has OpenH264, which takes a
    /// bitrate instead of a quality level.</summary>
    public static string[] H264 => Encoders.Contains("libx264") || !Encoders.Contains("libopenh264")
        ? ["-c:v", "libx264", "-preset", "medium", "-crf", Crf(false).ToString(), "-pix_fmt", "yuv420p"]
        : ["-c:v", "libopenh264", "-rc_mode", "quality", "-b:v", OpenH264Bitrate, "-pix_fmt", "yuv420p"];

    private static string OpenH264Bitrate => Settings.Current.VideoQuality switch { VideoQuality.High => "8M", VideoQuality.Balanced => "5M", _ => "2500k" };

    /// <summary>10-bit HEVC for HDR and deep-colour video; 8-bit H.264 when the build has no x265.</summary>
    public static string[] Hevc10 => Encoders.Contains("libx265") || Encoders.Count == 0
        ? ["-c:v", "libx265", "-preset", "medium", "-crf", Crf(true).ToString(), "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params", "log-level=error"]
        : H264;

    /// <summary>Video at an average bitrate (compression to a size): HEVC where the build has x265, otherwise H.264.</summary>
    public static string[] AtBitrate(long bits, bool deep)
    {
        string[] rate = ["-b:v", bits.ToString(), "-maxrate", ((long)(bits * 1.1)).ToString(), "-bufsize", bits.ToString()];
        if (Encoders.Contains("libx265") || Encoders.Count == 0)
            return ["-c:v", "libx265", "-preset", "medium", .. rate, "-tag:v", "hvc1", "-x265-params", "log-level=error", "-pix_fmt", deep ? "yuv420p10le" : "yuv420p"];
        if (Encoders.Contains("libx264")) return ["-c:v", "libx264", "-preset", "medium", .. rate, "-pix_fmt", "yuv420p"];
        return ["-c:v", "libopenh264", "-rc_mode", "bitrate", .. rate, "-pix_fmt", "yuv420p"];
    }

    public static Task Run(string input, string output, IEnumerable<string> arguments, double duration, Action<double>? progress,
                           IEnumerable<string>? inputOptions = null, CancellationToken cancellation = default) =>
        Run([.. inputOptions ?? [], "-i", input, .. arguments, output], duration, progress, cancellation);

    /// <summary>A complete argument list (several inputs, filter graphs).</summary>
    public static async Task Run(IEnumerable<string> arguments, double duration, Action<double>? progress, CancellationToken cancellation = default)
    {
        var ffmpeg = ProcessRunner.Require("ffmpeg");
        var result = await ProcessRunner.Run(ffmpeg, [.. Prefix, .. arguments], line =>
        {
            if (duration > 0 && line.StartsWith("out_time_us=") && double.TryParse(line[12..], CultureInfo.InvariantCulture, out var micros))
                progress?.Invoke(Math.Clamp(micros / 1_000_000 / duration, 0, 1));
        }, cancellation);
        if (result.ExitCode != 0)
        {
            var last = result.Error.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? $"exit code {result.ExitCode}";
            throw new AdawatException($"ffmpeg: {last}");
        }
    }

    /// <summary>Runs ffmpeg and returns its raw standard output (for decoded samples).</summary>
    public static async Task<byte[]> Capture(IEnumerable<string> arguments, CancellationToken cancellation = default)
    {
        var ffmpeg = ProcessRunner.Require("ffmpeg");
        var info = new System.Diagnostics.ProcessStartInfo(ffmpeg) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in (string[])["-hide_banner", "-nostdin", "-loglevel", "error", .. arguments]) info.ArgumentList.Add(argument);
        cancellation = ProcessRunner.Effective(cancellation);
        using var process = System.Diagnostics.Process.Start(info)!;
        _ = process.StandardError.ReadToEndAsync();
        using var memory = new MemoryStream();
        try
        {
            await process.StandardOutput.BaseStream.CopyToAsync(memory, cancellation);
            await process.WaitForExitAsync(cancellation);
        }
        catch (OperationCanceledException)
        {
            ProcessRunner.Stop(process);
            throw;
        }
        return memory.ToArray();
    }

    /// <summary>Runs ffmpeg and returns what it printed on standard error (filters such as loudnorm report there).</summary>
    public static async Task<string> Report(IEnumerable<string> arguments)
    {
        var ffmpeg = ProcessRunner.Require("ffmpeg");
        var result = await ProcessRunner.Run(ffmpeg, ["-hide_banner", "-nostdin", .. arguments]);
        return result.Error;
    }

    public static string Seconds(double value) => value.ToString("0.000", CultureInfo.InvariantCulture);
}
