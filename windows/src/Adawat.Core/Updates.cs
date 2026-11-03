using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Adawat.Core;

/// <summary>A newer Adawat on GitHub Releases: its notes, and the one file this computer installs from.</summary>
public sealed record Release(Version Version, string Notes, string Asset, Uri Download, string Sha256);

/// <summary>Asks GitHub Releases for a newer Adawat and downloads its installer, checked against the SHA-256 GitHub lists
/// for that file. The only time Adawat goes online, and only while "Check for updates" is on or the user asks.</summary>
public static class Updates
{
    public const string Repository = "motalim-ai/adawat";
    public static string ReleasesPage => $"https://github.com/{Repository}/releases/latest";

    /// <summary>Three parts, as release tags have: 1.1.0.0 would compare as newer than v1.1.0.</summary>
    public static Version Current { get; } = typeof(Updates).Assembly.GetName().Version is { } v ? new(v.Major, v.Minor, Math.Max(v.Build, 0)) : new(0, 0, 0);

    private static bool Arm => RuntimeInformation.OSArchitecture == Architecture.Arm64;

    /// <summary>The release file this computer installs from: the same names the README's download links use.</summary>
    public static string Asset =>
#if WINDOWS
        $"Adawat-Setup-{(Arm ? "arm64" : "x64")}.exe";
#else
        IsAppImage ? $"Adawat-{(Arm ? "aarch64" : "x86_64")}.AppImage"
        : File.Exists("/usr/bin/dpkg") ? $"Adawat-linux-{(Arm ? "arm64" : "amd64")}.deb"
        : $"Adawat-linux-{(Arm ? "aarch64" : "x86_64")}.rpm";

    public static string? AppImage => Environment.GetEnvironmentVariable("APPIMAGE") is { Length: > 0 } path ? path : null;
    public static bool IsAppImage => AppImage != null;
#endif

    private static HttpClient Client()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Adawat/{Current}");
        return http;
    }

    /// <summary>The latest release when it is newer than this app and has a file for this computer, otherwise null.</summary>
    public static async Task<Release?> Latest(CancellationToken cancel = default)
    {
        using var http = Client();
        http.Timeout = TimeSpan.FromSeconds(20);
        using var json = JsonDocument.Parse(await http.GetStringAsync($"https://api.github.com/repos/{Repository}/releases/latest", cancel));
        return Parse(json.RootElement, Asset);
    }

    internal static Release? Parse(JsonElement release, string asset)
    {
        if (!Version.TryParse(release.GetProperty("tag_name").GetString()?.TrimStart('v'), out var version) || version <= Current) return null;
        foreach (var file in release.GetProperty("assets").EnumerateArray())
        {
            if (file.GetProperty("name").GetString() != asset) continue;
            // No checksum, no install: the file could not be checked before it runs.
            if (!file.TryGetProperty("digest", out var digest) || digest.GetString() is not { } sha || !sha.StartsWith("sha256:")) return null;
            return new Release(version, release.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "", asset,
                               new Uri(file.GetProperty("browser_download_url").GetString()!), sha["sha256:".Length..]);
        }
        return null;
    }

    /// <summary>Downloads the release's file to <paramref name="path"/>, or throws and leaves nothing behind when it does
    /// not match its SHA-256.</summary>
    public static async Task Download(Release release, string path, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        var part = path + ".part";
        try
        {
            using var http = Client();
            using var response = await http.GetAsync(release.Download, HttpCompletionOption.ResponseHeadersRead, cancel);
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength ?? 0;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var input = await response.Content.ReadAsStreamAsync(cancel))
            await using (var output = File.Create(part))
            {
                var buffer = new byte[81920];
                long done = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, cancel)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancel);
                    hash.AppendData(buffer, 0, read);
                    done += read;
                    if (total > 0) progress?.Report((double)done / total);
                }
            }
            if (!Convert.ToHexString(hash.GetHashAndReset()).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new AdawatException("The update did not download correctly. Try again later.");
            File.Move(part, path, true);
        }
        finally
        {
            File.Delete(part);
        }
    }
}
