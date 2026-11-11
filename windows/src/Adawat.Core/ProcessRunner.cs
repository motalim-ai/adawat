using System.Diagnostics;
using System.Text;

namespace Adawat.Core;

/// <summary>Runs the bundled command-line tools (ffmpeg, ffprobe) and finds them.</summary>
public static class ProcessRunner
{
    /// <summary>tools\ next to Adawat.exe (tools/ next to the Linux app), then the PATH.</summary>
    public static string? Find(string name)
    {
        var exe = !OperatingSystem.IsWindows() || name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
        var bundled = Path.Combine(AppContext.BaseDirectory, "tools", exe);
        if (File.Exists(bundled)) return bundled;
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(folder.Trim(), exe);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    public static string Require(string name) =>
        Find(name) ?? throw new AdawatException(OperatingSystem.IsWindows()
            ? $"{name} is not installed. Install it with: winget install {name}"
            : $"{name} is not installed. Install it with: {InstallCommand(name)}");

#if WINDOWS
    private static string InstallCommand(string name) => name;
#else
    private static string InstallCommand(string name) => Desktop.Install(name);
#endif

    public sealed record Result(int ExitCode, string Output, string Error);

    /// <summary>The running operation's Cancel (see <see cref="OperationContext.Run"/>), used when a call passes no token.</summary>
    public static readonly AsyncLocal<CancellationToken> Ambient = new();

    /// <summary><paramref name="cancellation"/>, or the running operation's when the caller passed none.</summary>
    public static CancellationToken Effective(CancellationToken cancellation) => cancellation.CanBeCanceled ? cancellation : Ambient.Value;

    /// <summary>Runs <paramref name="tool"/> and waits. Lines on standard output are passed to <paramref name="onLine"/>.</summary>
    public static async Task<Result> Run(string tool, IEnumerable<string> arguments, Action<string>? onLine = null,
                                         CancellationToken cancellation = default, string? input = null)
    {
        cancellation = Effective(cancellation);
        cancellation.ThrowIfCancellationRequested();
        var info = new ProcessStartInfo(tool)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = input != null,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = info };
        var output = new StringBuilder();
        var error = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (output) output.AppendLine(e.Data);
            onLine?.Invoke(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (error) error.AppendLine(e.Data);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (input != null)
        {
            await process.StandardInput.WriteAsync(input);
            process.StandardInput.Close();
        }
        try
        {
            await process.WaitForExitAsync(cancellation);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }
        process.WaitForExit();
        return new Result(process.ExitCode, output.ToString(), error.ToString());
    }
}
