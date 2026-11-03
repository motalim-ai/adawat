using System.Windows;
using Adawat.Core;

namespace Adawat.App;

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
        var dispatcher = Application.Current.Dispatcher;
        var context = new OperationContext(
            text => dispatcher.BeginInvoke(() => hud.Update(text)),
            fraction => dispatcher.BeginInvoke(() => hud.SetProgress(fraction)));
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

