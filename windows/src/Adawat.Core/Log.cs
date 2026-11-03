namespace Adawat.Core;

/// <summary>A small log next to settings.json (%APPDATA%\Adawat\adawat.log, ~/.config/Adawat/adawat.log on Linux), for bug reports.</summary>
public static class Log
{
    private static readonly string FilePath = Path.Combine(Settings.Folder, "adawat.log");
    private static readonly object Gate = new();

    public static void Write(string text)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Settings.Folder);
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 2_000_000) File.Delete(FilePath);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {text}{Environment.NewLine}");
            }
        }
        catch (IOException) { }
    }
}
