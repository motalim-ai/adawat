namespace Adawat.Core;

/// <summary>Where results go and what they are called. Originals are never changed.</summary>
public static class Output
{
    public static string Directory(string source)
    {
        switch (Settings.Current.OutputLocation)
        {
            case OutputLocation.Downloads: return Downloads;
            case OutputLocation.Desktop: return DesktopFolder;
        }
        var parent = Path.GetDirectoryName(Path.GetFullPath(source)) ?? Downloads;
        return Writable.GetOrAdd(parent, IsWritable) ? parent : Downloads;
    }

#if WINDOWS
    public static string Downloads =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    private static string DesktopFolder => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
#else
    // On Linux the folders have translated names (التنزيلات on an Arabic system), listed in ~/.config/user-dirs.dirs.
    public static string Downloads => Desktop.UserFolder("DOWNLOAD", "Downloads");

    private static string DesktopFolder => Desktop.UserFolder("DESKTOP", "Desktop");
#endif

    /// <summary>A free path named after <paramref name="source"/>, with a new extension and optional suffix.</summary>
    public static string PathFor(string source, string extension, string? suffix = null)
    {
        var name = Path.GetFileNameWithoutExtension(source);
        if (name.EndsWith(".tar", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        if (suffix != null) name = $"{name} {suffix}";
        return Unique(Path.Combine(Directory(source), $"{name}.{extension}"));
    }

    /// <summary>A free path called <paramref name="name"/> in the output folder for <paramref name="source"/>.</summary>
    public static string Named(string name, string source) => Unique(Path.Combine(Directory(source), name));

    /// <summary>Appends " 2", " 3"… until the name is free.</summary>
    public static string Unique(string path)
    {
        if (!File.Exists(path) && !System.IO.Directory.Exists(path)) return path;
        var folder = Path.GetDirectoryName(path)!;
        var ext = Path.GetExtension(path);
        var stem = Path.GetFileNameWithoutExtension(path);
        for (var index = 2; ; index++)
        {
            var candidate = Path.Combine(folder, $"{stem} {index}{ext}");
            if (!File.Exists(candidate) && !System.IO.Directory.Exists(candidate)) return candidate;
        }
    }

    /// <summary>A scratch folder that is removed when disposed.</summary>
    public static TempFolder Temp() => new();

    /// <summary>Probed once per folder: each probe is a real file, which synced folders would upload and delete again.</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> Writable = new();

    private static bool IsWritable(string folder)
    {
        try
        {
            var probe = Path.Combine(folder, $".adawat-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }
}

public sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Adawat", Guid.NewGuid().ToString("N"));

    public TempFolder() => Directory.CreateDirectory(Path);

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
