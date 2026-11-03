using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Adawat.Core;

namespace Adawat.App;

/// <summary>Tells the user a newer Adawat is out, shows what changed, and installs it: the installer runs silently,
/// closes this copy and starts the new one.</summary>
public static class UpdateWindow
{
    private static ToolWindow? _open;

    /// <summary>At start, when "Check for updates" is on: quiet unless there is something to install.</summary>
    public static async void CheckAtStart()
    {
        var settings = Settings.Current;
        if (!settings.CheckForUpdates) return;
        try
        {
            if (await Updates.Latest() is { } release && release.Version.ToString() != settings.SkippedVersion) Present(release);
        }
        catch (Exception e) { Log.Write($"update check failed: {e.Message}"); }
    }

    /// <summary>From the menu or Settings: always answers.</summary>
    public static async void CheckNow()
    {
        Hud.Shared.ShowMessage("Checking for updates…", Hud.Style.Working);
        try
        {
            if (await Updates.Latest() is { } release)
            {
                Hud.Shared.ShowMessage($"Adawat {release.Version} is available", Hud.Style.Success);
                Present(release);
            }
            else Hud.Shared.ShowMessage($"Adawat {Updates.Current} is the latest version", Hud.Style.Success);
        }
        catch (Exception e)
        {
            Log.Write($"update check failed: {e.Message}");
            Hud.Shared.ShowMessage("Could not check for updates. Check your internet connection.", Hud.Style.Failure);
        }
    }

    private static void Present(Release release)
    {
        _open?.Close();
        var window = Make(release);
        window.Closed += (_, _) => { if (_open == window) _open = null; };
        _open = window;
        window.Present();
    }

    public static ToolWindow Make(Release release)
    {
        var window = new ToolWindow("Update Adawat", 460);
        var stack = new StackPanel();
        stack.Children.Add(UI.Text(L10n.T($"Adawat {release.Version} is available. You have {Updates.Current}."), 13, FontWeights.SemiBold, wrap: true));
        stack.Children.Add(UI.Caption("Your settings and files stay as they are.").Pad(0, 4));
        if (release.Notes.Length > 0)
        {
            stack.Children.Add(UI.Text("What's new", 12, FontWeights.SemiBold, Theme.Muted).Pad(0, 6));
            // Release notes are mostly English, so they read left to right in either language.
            var notes = new TextBlock { Text = release.Notes.Replace("\r", ""), TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Theme.Ink, FlowDirection = FlowDirection.LeftToRight };
            stack.Children.Add(new ScrollViewer { Content = notes, MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
        window.Body = stack;
        window.Leading(UI.Button("Skip This Version", () =>
        {
            Settings.Current.SkippedVersion = release.Version.ToString();
            Settings.Current.Save();
            window.Close();
        }));
        window.Trailing(UI.Button("Later", window.Close), UI.Button("Update Now", () => { window.Close(); Install(release); }, primary: true));
        return window;
    }

    private static async void Install(Release release)
    {
        Hud.Shared.ShowMessage("Downloading the update…", Hud.Style.Working);
        try
        {
            var installer = Path.Combine(Path.GetTempPath(), release.Asset);
            await Updates.Download(release, installer, new Progress<double>(Hud.Shared.SetProgress));
            // The installer closes this copy itself (PrepareToInstall) and starts the new one when silent.
            // Without "!startup" it would turn "Start Adawat when Windows starts" back on.
            var args = "/SILENT /SUPPRESSMSGBOXES /NORESTART" + (Startup.IsEnabled ? "" : " /MERGETASKS=!startup");
            Process.Start(new ProcessStartInfo(installer, args) { UseShellExecute = true });
            Application.Current.Shutdown();
        }
        catch (Exception e)
        {
            Log.Write($"update failed: {e}");
            Hud.Shared.ShowMessage(e is AdawatException ? e.Message : "Could not download the update. Check your internet connection.", Hud.Style.Failure);
        }
    }
}
