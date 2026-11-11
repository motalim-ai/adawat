using System.Text.Json;

namespace Adawat.Core.Media;

public sealed record MediaFormat(string Name, string Ext, bool AudioOnly)
{
    public static readonly MediaFormat Mp4 = new("MP4", "mp4", false);
    public static readonly MediaFormat Mov = new("MOV", "mov", false);
    public static readonly MediaFormat Mkv = new("MKV", "mkv", false);
    public static readonly MediaFormat WebM = new("WebM", "webm", false);
    public static readonly MediaFormat Gif = new("GIF", "gif", false);
    public static readonly MediaFormat Mp3 = new("MP3", "mp3", true);
    public static readonly MediaFormat M4a = new("M4A", "m4a", true);
    public static readonly MediaFormat Wav = new("WAV", "wav", true);
    public static readonly MediaFormat Flac = new("FLAC", "flac", true);
    public static readonly MediaFormat Aiff = new("AIFF", "aiff", true);
    public static readonly MediaFormat Ogg = new("OGG", "ogg", true);
    public static readonly MediaFormat Opus = new("Opus", "opus", true);

    public static readonly IReadOnlyList<MediaFormat> Video = [Mp4, Mov, Mkv, WebM, Gif, Mp3, M4a];
    public static readonly IReadOnlyList<MediaFormat> Audio = [Mp3, M4a, Wav, Flac, Aiff, Ogg, Opus];
}

/// <summary>Video and audio conversions and one-step tools, all through ffmpeg.</summary>
public static class MediaOps
{
    /// <summary>Codecs each container holds as they are, so converting only re-wraps the streams: instant and lossless.</summary>
    private static readonly Dictionary<string, HashSet<string>> CopyableVideo = new()
    {
        ["mp4"] = ["h264", "hevc", "av1"],
        ["mov"] = ["h264", "hevc", "prores", "mjpeg"],
        ["mkv"] = ["h264", "hevc", "vp9", "av1", "prores", "mpeg4"],
        ["webm"] = ["vp9", "av1"],
    };
    private static readonly Dictionary<string, HashSet<string>> CopyableAudio = new()
    {
        ["mp4"] = ["aac", "alac", "mp3"],
        ["mov"] = ["aac", "alac", "mp3", "pcm"],
        ["mkv"] = ["aac", "alac", "mp3", "pcm", "opus", "flac", "ac3", "eac3", "vorbis"],
        ["webm"] = ["opus", "vorbis"],
    };

    public static string[] ConversionArguments(MediaFormat format, MediaInfo info)
    {
        if (format.AudioOnly) return AudioArguments(format, info);
        if (!info.HasVideo) throw new AdawatException("This file has no video track");
        if (format == MediaFormat.Gif)
        {
            return ["-an", "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"];
        }
        var container = format.Ext;
        var keepVideo = CopyableVideo.TryGetValue(container, out var videoCodecs) && videoCodecs.Contains(info.VideoCodec ?? "");
        var keepAudio = !info.HasAudio || (CopyableAudio.TryGetValue(container, out var audioCodecs) && audioCodecs.Contains(info.AudioCodec ?? ""));
        var args = new List<string> { "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0" };
        if (keepVideo)
        {
            args.AddRange(["-c:v", "copy"]);
            if (info.VideoCodec == "hevc" && container != "mkv") args.AddRange(["-tag:v", "hvc1"]);
            args.AddRange(["-strict", "unofficial"]);
        }
        else if (container == "webm")
        {
            args.AddRange(FFmpeg.WebMVideo());
        }
        else
        {
            args.AddRange(info.IsHighDepth ? FFmpeg.Hevc10 : FFmpeg.H264);
        }
        if (keepAudio) args.AddRange(["-c:a", "copy"]);
        else if (container == "webm") args.AddRange(["-c:a", "libopus", "-b:a", "128k"]);
        else args.AddRange(["-c:a", FFmpeg.Aac, "-b:a", "192k"]);
        if (container is "mp4" or "mov") args.AddRange(["-movflags", "+faststart"]);
        return [.. args];
    }

    private static string[] AudioArguments(MediaFormat format, MediaInfo info)
    {
        if (!info.HasAudio) throw new AdawatException("This file has no audio track");
        var source = info.AudioCodec ?? "";
        var deep = info.AudioBits >= 24;
        string[] args = ["-vn", "-map", "0:a:0", "-map_metadata", "0"];
        string[] codec = format.Ext switch
        {
            "m4a" => source is "alac" or "aac" ? ["-c:a", "copy"] : ["-c:a", FFmpeg.Aac, "-b:a", "256k"],
            "mp3" => source == "mp3" ? ["-c:a", "copy"] : ["-c:a", "libmp3lame", "-q:a", "2"],
            "wav" => ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"],
            "aiff" => ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"],
            "flac" => source == "flac" ? ["-c:a", "copy"] : ["-c:a", "flac"],
            "ogg" => source == "vorbis" ? ["-c:a", "copy"] : ["-c:a", "libvorbis", "-q:a", "5"],
            "opus" => source == "opus" ? ["-c:a", "copy"] : ["-c:a", "libopus", "-b:a", "160k"],
            _ => [],
        };
        return [.. args, .. codec];
    }

    public static async Task<IReadOnlyList<string>> Convert(IReadOnlyList<string> files, MediaFormat format, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            context.Report($"Converting {index + 1} of {files.Count} to {format.Name}");
            var file = files[index];
            var info = await MediaProbe.Info(file);
            var output = Output.PathFor(file, format.Ext);
            await Encode(file, output, ConversionArguments(format, info), info, context.ProgressFor(index, files.Count), context: context);
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>Runs ffmpeg and removes a half-written output if it fails.</summary>
    public static async Task Encode(string file, string output, IEnumerable<string> arguments, MediaInfo info, Action<double>? progress,
                                    IEnumerable<string>? inputOptions = null, OperationContext? context = null)
    {
        try
        {
            await FFmpeg.Run(file, output, arguments, info.Duration, progress, inputOptions, context?.Cancellation ?? default);
        }
        catch
        {
            TryDelete(output);
            throw;
        }
    }

    public static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // MARK: Lossless edits

    public static Task<IReadOnlyList<string>> Mute(IReadOnlyList<string> files, OperationContext context) =>
        StreamCopy(files, "muted", context, ["-map", "0:v", "-c", "copy", "-an"]);

    /// <summary>Strips container tags, chapters and the timed-metadata tracks where phones store location.</summary>
    public static async Task<IReadOnlyList<string>> StripMetadata(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = await StreamCopy(files, "clean", context,
            ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact",
             "-flags:a", "+bitexact", "-c", "copy"]);
        context.Finish(files.Count == 1 ? "Metadata removed from 1 file" : $"Metadata removed from {files.Count} files");
        return outputs;
    }

    private static async Task<IReadOnlyList<string>> StreamCopy(IReadOnlyList<string> files, string suffix, OperationContext context, string[] arguments)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            var file = files[index];
            var info = await MediaProbe.Info(file);
            var output = Output.PathFor(file, FileKinds.Ext(file), suffix);
            await Encode(file, output, arguments, info, context.ProgressFor(index, files.Count), context: context);
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>Turns the video 90° clockwise by changing its display rotation, without re-encoding.</summary>
    public static async Task<IReadOnlyList<string>> Rotate(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        foreach (var file in files)
        {
            var info = await MediaProbe.Info(file);
            var output = Output.PathFor(file, FileKinds.Ext(file), "rotated");
            await Encode(file, output, ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-c", "copy"], info, null,
                         ["-display_rotation:v:0", "-90"], context);
            outputs.Add(output);
        }
        return outputs;
    }

    // MARK: Join

    /// <summary>Plays the clips one after another in a single MP4. Matching H.264/HEVC clips are joined without re-encoding;
    /// mixed clips are fitted onto the first clip's frame.</summary>
    public static async Task<IReadOnlyList<string>> Join(IReadOnlyList<string> files, OperationContext context)
    {
        if (files.Count < 2) throw new AdawatException("Select at least two videos to join.");
        var infos = new List<MediaInfo>();
        foreach (var file in files) infos.Add(await MediaProbe.Info(file));
        if (!infos.All(info => info.HasVideo)) throw new AdawatException("Every selected file must contain a video track.");
        var first = infos[0];
        var total = infos.Sum(info => info.Duration);
        var output = Output.Named($"{Path.GetFileNameWithoutExtension(files[0])} joined.mp4", files[0]);
        var progress = context.ProgressFor(0, 1);

        var sameShape = infos.All(info => info.VideoCodec == first.VideoCodec && info.Width == first.Width && info.Height == first.Height
                                          && info.AudioCodec == first.AudioCodec && info.IsHighDepth == first.IsHighDepth);
        if (sameShape && first.VideoCodec is "h264" or "hevc" && first.AudioCodec is null or "aac")
        {
            context.Report($"Joining {files.Count} videos");
            using var temp = Output.Temp();
            var list = temp.File("list.txt");
            await File.WriteAllLinesAsync(list, files.Select(file => $"file '{file.Replace("'", "'\\''")}'"));
            var args = new List<string> { "-f", "concat", "-safe", "0", "-i", list, "-map", "0:v", "-map", "0:a?", "-c", "copy" };
            if (first.VideoCodec == "hevc") args.AddRange(["-tag:v", "hvc1"]);
            args.AddRange(["-movflags", "+faststart", output]);
            try
            {
                await FFmpeg.Run(args, total, progress, context.Cancellation);
                return [output];
            }
            catch (AdawatException)
            {
                // Streams that look alike can still disagree in detail; fall through to re-encoding.
                TryDelete(output);
            }
            catch (OperationCanceledException)
            {
                TryDelete(output);
                throw;
            }
        }

        context.Report($"Encoding {files.Count} videos into one");
        int width = first.Width > 0 ? first.Width : 1920, height = first.Height > 0 ? first.Height : 1080;
        var deep = infos.Any(info => info.IsHighDepth);
        var inputs = new List<string>();
        var graph = new System.Text.StringBuilder();
        for (var index = 0; index < files.Count; index++)
        {
            inputs.AddRange(["-i", files[index]]);
            graph.Append($"[{index}:v]scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format={(deep ? "yuv420p10le" : "yuv420p")}[v{index}];");
        }
        var silent = files.Count;
        for (var index = 0; index < infos.Count; index++)
        {
            if (infos[index].HasAudio)
            {
                graph.Append($"[{index}:a]aformat=sample_rates=48000:channel_layouts=stereo,asetpts=PTS-STARTPTS[a{index}];");
            }
            else
            {
                // Clips without sound get matching silence so the audio stays in step with the pictures.
                inputs.AddRange(["-f", "lavfi", "-t", FFmpeg.Seconds(infos[index].Duration), "-i", "anullsrc=r=48000:cl=stereo"]);
                graph.Append($"[{silent}:a]asetpts=PTS-STARTPTS[a{index}];");
                silent++;
            }
        }
        graph.Append(string.Concat(Enumerable.Range(0, files.Count).Select(i => $"[v{i}][a{i}]")) + $"concat=n={files.Count}:v=1:a=1[v][a]");
        try
        {
            await FFmpeg.Run([.. inputs, "-filter_complex", graph.ToString(), "-map", "[v]", "-map", "[a]",
                              .. deep ? FFmpeg.Hevc10 : FFmpeg.H264, "-c:a", FFmpeg.Aac, "-b:a", "192k", "-movflags", "+faststart", output],
                             total, progress, context.Cancellation);
        }
        catch
        {
            TryDelete(output);
            throw;
        }
        return [output];
    }

    // MARK: Trim

    /// <summary>Keeps start…end. Audio-only files are cut without re-encoding; video is re-encoded so the cut lands on the exact frame.</summary>
    public static async Task<string> Trim(string file, double start, double end, bool trimSilence, OperationContext context)
    {
        var ext = FileKinds.Ext(file);
        var output = Output.PathFor(file, ext, "trimmed");
        var info = await MediaProbe.Info(file);
        var length = Math.Max(0.05, end - start);
        string[] window = ["-ss", FFmpeg.Seconds(start), "-t", FFmpeg.Seconds(length)];
        if (trimSilence)
        {
            await Encode(file, output, ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-af", SilenceFilter, .. AudioCodec(ext, info.AudioBits >= 24)],
                         info with { Duration = length }, context.ProgressFor(0, 1), window, context);
            return output;
        }
        await CutSegment(file, start, end, output, info, context.ProgressFor(0, 1), context);
        return output;
    }

    public static async Task CutSegment(string file, double start, double end, string output, MediaInfo info, Action<double>? progress,
                                        OperationContext? context = null)
    {
        var ext = FileKinds.Ext(file);
        var length = Math.Max(0.05, end - start);
        var args = new List<string> { "-map", "0:v?", "-map", "0:a?", "-map_metadata", "0" };
        if (info.HasVideo)
        {
            if (ext == "webm") args.AddRange([.. FFmpeg.WebMVideo(30), "-c:a", "libopus", "-b:a", "160k"]);
            else args.AddRange([.. info.IsHighDepth ? FFmpeg.Hevc10 : FFmpeg.H264, "-c:a", FFmpeg.Aac, "-b:a", "192k"]);
            if (ext is "mp4" or "mov" or "m4v") args.AddRange(["-movflags", "+faststart"]);
        }
        else
        {
            args.AddRange(["-c", "copy"]);
        }
        await Encode(file, output, args, info with { Duration = length }, progress, ["-ss", FFmpeg.Seconds(start), "-t", FFmpeg.Seconds(length)], context);
    }

    /// <summary>Peak levels (0…1) across the file for drawing a waveform, decoded at a low rate.</summary>
    public static async Task<float[]> Waveform(string file, int bars, int? channel = null)
    {
        string[] mix = channel is { } c ? ["-af", $"pan=mono|c0=c{c}"] : ["-ac", "1"];
        byte[] data;
        try { data = await FFmpeg.Capture(["-i", file, "-vn", .. mix, "-ar", "4000", "-f", "f32le", "-"]); }
        catch (AdawatException) { return []; }
        var samples = new float[data.Length / 4];
        Buffer.BlockCopy(data, 0, samples, 0, samples.Length * 4);
        if (samples.Length == 0 || bars <= 0) return [];
        var chunk = Math.Max(1, samples.Length / bars);
        var peaks = new List<float>();
        for (var index = 0; index < samples.Length && peaks.Count < bars; index += chunk)
        {
            var peak = 0f;
            for (var i = index; i < Math.Min(index + chunk, samples.Length); i++) peak = Math.Max(peak, Math.Abs(samples[i]));
            peaks.Add(peak);
        }
        var top = peaks.Max();
        return top > 0 ? peaks.Select(p => p / top).ToArray() : [.. peaks];
    }

    // MARK: Audio tools

    private const string SilenceEdge = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.1";
    private const string SilenceFilter = SilenceEdge + ",areverse," + SilenceEdge + ",areverse";

    public sealed record Loudness(string I, string Tp, string Lra, string Thresh, string Offset);

    /// <summary>Two-pass EBU R128 normalization: the first pass measures the file so the second can hit the target exactly.</summary>
    public static async Task<IReadOnlyList<string>> Normalize(IReadOnlyList<string> files, OperationContext context) =>
        await Normalize(files, -16, 11, -1.5, context);

    public static async Task<IReadOnlyList<string>> Normalize(IReadOnlyList<string> files, double integrated, double range, double peak, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            var file = files[index];
            context.Report($"Measuring loudness {index + 1} of {files.Count}");
            var info = await MediaProbe.Info(file);
            if (!info.HasAudio) throw new AdawatException($"{Path.GetFileName(file)} has no audio track");
            var target = $"I={Num(integrated)}:TP={Num(peak)}:LRA={Num(range)}";
            var filter = $"loudnorm={target}";
            if (await MeasureLoudness(file, target) is { } m)
                filter += $":measured_I={m.I}:measured_TP={m.Tp}:measured_LRA={m.Lra}:measured_thresh={m.Thresh}:offset={m.Offset}:linear=true";
            context.Report($"Normalizing {index + 1} of {files.Count}");
            var ext = FileKinds.Ext(file);
            var args = new List<string> { "-map", "0:v?", "-map", "0:a", "-map_metadata", "0", "-af", filter };
            if (info.HasVideo) args.AddRange(["-c:v", "copy"]);
            args.AddRange(AudioCodec(ext, info.AudioBits >= 24));
            // loudnorm works at 192 kHz internally; return to a standard rate.
            args.AddRange(["-ar", "48000"]);
            var output = Output.PathFor(file, ext, "normalized");
            await Encode(file, output, args, info, context.ProgressFor(index, files.Count), context: context);
            outputs.Add(output);
        }
        return outputs;
    }

    private static string Num(double value) => value.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture);

    public static async Task<Loudness?> MeasureLoudness(string file, string target = "I=-16:TP=-1.5:LRA=11")
    {
        var report = await FFmpeg.Report(["-i", file, "-vn", "-af", $"loudnorm={target}:print_format=json", "-f", "null", "-"]);
        var start = report.LastIndexOf('{');
        var end = report.LastIndexOf('}');
        if (start < 0 || end < start) return null;
        try
        {
            using var json = JsonDocument.Parse(report[start..(end + 1)]);
            var root = json.RootElement;
            string Get(string key) => root.GetProperty(key).GetString() ?? "0";
            return new Loudness(Get("input_i"), Get("input_tp"), Get("input_lra"), Get("input_thresh"), Get("target_offset"));
        }
        catch (JsonException) { return null; }
    }

    public static async Task<IReadOnlyList<string>> ToMono(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            var file = files[index];
            var info = await MediaProbe.Info(file);
            if (!info.HasAudio) throw new AdawatException($"{Path.GetFileName(file)} has no audio track");
            var args = new List<string> { "-map", "0:v?", "-map", "0:a", "-map_metadata", "0", "-ac", "1" };
            if (info.HasVideo) args.AddRange(["-c:v", "copy"]);
            args.AddRange(AudioCodec(FileKinds.Ext(file), info.AudioBits >= 24));
            var output = Output.PathFor(file, FileKinds.Ext(file), "mono");
            await Encode(file, output, args, info, context.ProgressFor(index, files.Count), context: context);
            outputs.Add(output);
        }
        return outputs;
    }

    /// <summary>Cuts leading and trailing silence quieter than -45 dB.</summary>
    public static async Task<IReadOnlyList<string>> TrimSilence(IReadOnlyList<string> files, OperationContext context)
    {
        var outputs = new List<string>();
        for (var index = 0; index < files.Count; index++)
        {
            var file = files[index];
            var info = await MediaProbe.Info(file);
            var output = Output.PathFor(file, FileKinds.Ext(file), "trimmed");
            await Encode(file, output, ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-af", SilenceFilter, .. AudioCodec(FileKinds.Ext(file), info.AudioBits >= 24)],
                         info, context.ProgressFor(index, files.Count), context: context);
            outputs.Add(output);
        }
        return outputs;
    }

    public static string[] AudioCodec(string ext, bool deep) => ext switch
    {
        "mp3" => ["-c:a", "libmp3lame", "-q:a", "2"],
        "m4a" or "mp4" or "mov" or "m4v" or "aac" => ["-c:a", FFmpeg.Aac, "-b:a", "192k"],
        "wav" => ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"],
        "aif" or "aiff" => ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"],
        "flac" => ["-c:a", "flac"],
        "ogg" => ["-c:a", "libvorbis", "-q:a", "5"],
        "webm" or "opus" or "mkv" => ["-c:a", "libopus", "-b:a", "160k"],
        "wma" => ["-c:a", "wmav2", "-b:a", "192k"],
        _ => [],
    };

    // MARK: Frames

    /// <summary>A full-resolution still at <paramref name="time"/> seconds.</summary>
    public static async Task Frame(string file, double time, string output)
    {
        var info = await MediaProbe.Info(file);
        await Encode(file, output, ["-frames:v", "1", "-update", "1"], info, null, ["-ss", FFmpeg.Seconds(time)]);
    }
}
