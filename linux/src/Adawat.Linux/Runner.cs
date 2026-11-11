using Avalonia.Threading;
using Adawat.Core;

namespace Adawat.Linux;

/// <summary>Runs a wheel choice or a tool window's job with the same toast, sound and Float.</summary>
public static class Runner
{
    /// <summary>A drop on the wheel: tools with options open their window, everything else runs right away.</summary>
    public static void Start(AdawatOperation operation, IReadOnlyList<string> files)
    {
        if (operation.Window is { } window && ToolWindows.Open(window, files)) return;
        Run(operation, files);
    }

    public static void Run(string title, IReadOnlyList<string> files, OperationWork work, bool producesFiles = true) =>
        Run(new AdawatOperation("window", title, "", work) { ProducesFiles = producesFiles }, files);

    /// <summary>The work in progress, each with its Cancel. Touched on the UI thread only.</summary>
    private static readonly List<CancellationTokenSource> Running = [];

    /// <summary>The toast's Cancel button: stops everything in progress, since the one toast speaks for all of it.</summary>
    public static void CancelAll()
    {
        foreach (var source in Running) source.Cancel();
    }

    public static async void Run(AdawatOperation operation, IReadOnlyList<string> files)
    {
        var hud = Hud.Shared;
        using var cancel = new CancellationTokenSource();
        Running.Add(cancel);
        // Actions (Share, Move, Copy…) are over at once or wait on a dialog of their own; only work that makes files offers Cancel.
        hud.ShowMessage($"{operation.Title}…", Hud.Style.Working, operation.ProducesFiles ? CancelAll : null);
        var context = new OperationContext(
            text => Dispatcher.UIThread.Post(() => hud.Update(text)),
            fraction => Dispatcher.UIThread.Post(() => hud.SetProgress(fraction)),
            cancel.Token);
        try
        {
            var outputs = await Task.Run(() => context.Run(operation.Run, files));
            var message = context.Message ?? outputs.Count switch
            {
                0 => $"{operation.Title} done",
                1 => $"Saved {Path.GetFileName(outputs[0])}",
                _ => $"Saved {outputs.Count} files",
            };
            hud.ShowMessage(message, Hud.Style.Success);
            Sounds.Done();
            if (operation.ProducesFiles && outputs.Count > 0 && Settings.Current.ShowResultsInFloat) Floats.ShowResults(outputs);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            hud.ShowMessage("Cancelled", Hud.Style.Cancelled);
        }
        catch (Exception e)
        {
            Log.Write($"{operation.Id} failed: {e}");
            hud.ShowMessage(e is AdawatException ? e.Message : L10n.T("Something went wrong: ") + e.Message, Hud.Style.Failure);
            Sounds.Failed();
        }
        finally
        {
            Running.Remove(cancel);
        }
    }
}

/// <summary>A small log in ~/.config/Adawat/adawat.log, for bug reports.</summary>
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

/// <summary>Every options window by the name the catalog gives it.</summary>
public static class ToolWindows
{
    private static readonly Dictionary<string, Func<IReadOnlyList<string>, Avalonia.Controls.Window?>> Makers = new();

    public static IEnumerable<string> Names { get { EnsureRegistered(); return Makers.Keys; } }

    public static void Register(string name, Func<IReadOnlyList<string>, Avalonia.Controls.Window?> maker) => Makers[name] = maker;

    /// <summary>Opens the window for <paramref name="name"/>; false when there is none, so the one-step version runs instead.</summary>
    public static bool Open(string name, IReadOnlyList<string> files)
    {
        EnsureRegistered();
        if (!Makers.TryGetValue(name, out var make)) return false;
        try
        {
            var window = make(files);
            if (window == null) return true;
            if (window is ToolWindow tool) tool.Present(); else { window.Show(); window.Activate(); }
            return true;
        }
        catch (AdawatException e)
        {
            Hud.Shared.ShowMessage(e.Message, Hud.Style.Failure);
            return true;
        }
    }

    public static Avalonia.Controls.Window? Make(string name, IReadOnlyList<string> files)
    {
        EnsureRegistered();
        return Makers.TryGetValue(name, out var make) ? make(files) : null;
    }

    private static bool _registered;

    private static void EnsureRegistered()
    {
        if (_registered) return;
        _registered = true;
        Windows.Catalog.RegisterAll();
    }
}
