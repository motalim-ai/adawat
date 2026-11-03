using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Adawat.Core;

namespace Adawat.Linux;

/// <summary>Tells the user a newer Adawat is out, shows what changed, and installs it. An AppImage replaces itself and
/// restarts; a .deb or .rpm needs the system's password, so the package is downloaded and handed to the software installer.</summary>
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
        stack.Children.Add(UI.Text(L10n.T($"Adawat {release.Version} is available. You have {Updates.Current}."), 13, FontWeight.SemiBold, wrap: true));
        stack.Children.Add(UI.Caption("Your settings and files stay as they are.").Pad(0, 4));
        if (release.Notes.Length > 0)
        {
            stack.Children.Add(UI.Text("What's new", 12, FontWeight.SemiBold, Look.Muted).Pad(0, 6));
            // Release notes are mostly English, so they read left to right in either language.
            var notes = new TextBlock { Text = release.Notes.Replace("\r", ""), TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Look.Ink, FlowDirection = FlowDirection.LeftToRight };
            stack.Children.Add(new ScrollViewer { Content = notes, MaxHeight = 260, HorizontalAlignment = HorizontalAlignment.Stretch });
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
            var progress = new Progress<double>(Hud.Shared.SetProgress);
            if (Updates.AppImage is { } image)
            {
                // Downloaded beside the AppImage so the move that replaces it stays on one disk; the running copy keeps
                // its open file until the restart.
                var download = Path.Combine(Path.GetDirectoryName(image)!, ".adawat-update.AppImage");
                await Updates.Download(release, download, progress);
                File.SetUnixFileMode(download, File.GetUnixFileMode(image) | UnixFileMode.UserExecute);
                File.Move(download, image, true);
                SettingsWindow.Restart();
                return;
            }
            var package = Path.Combine(Output.Downloads, release.Asset);
            await Updates.Download(release, package, progress);
            Hud.Shared.ShowMessage("Install the downloaded package to finish the update", Hud.Style.Success);
            Core.Desktop.Open(package);
        }
        catch (UnauthorizedAccessException)
        {
            Hud.Shared.ShowMessage("Adawat cannot replace itself in this folder. Download the new version from GitHub.", Hud.Style.Failure);
            Core.Desktop.Open(Updates.ReleasesPage);
        }
        catch (Exception e)
        {
            Log.Write($"update failed: {e}");
            Hud.Shared.ShowMessage(e is AdawatException ? e.Message : "Could not download the update. Check your internet connection.", Hud.Style.Failure);
        }
    }
}
