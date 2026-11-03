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

    public static async void Run(AdawatOperation operation, IReadOnlyList<string> files)
    {
        var hud = Hud.Shared;
        hud.ShowMessage($"{operation.Title}…", Hud.Style.Working);
        var context = new OperationContext(
            text => Dispatcher.UIThread.Post(() => hud.Update(text)),
            fraction => Dispatcher.UIThread.Post(() => hud.SetProgress(fraction)));
        try
        {
            var outputs = await Task.Run(() => operation.Run(files, context));
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
        catch (Exception e)
        {
            Log.Write($"{operation.Id} failed: {e}");
            hud.ShowMessage(e is AdawatException ? e.Message : L10n.T("Something went wrong: ") + e.Message, Hud.Style.Failure);
            Sounds.Failed();
        }
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
