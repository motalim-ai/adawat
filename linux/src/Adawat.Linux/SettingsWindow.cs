using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Adawat.Core;
using Adawat.Linux.Desktop;

namespace Adawat.Linux;

/// <summary>Keys, where results go, compression defaults, startup and language.</summary>
public static class SettingsWindow
{
    private static ToolWindow? _open;

    public static void Present()
    {
        if (_open != null) { _open.Activate(); return; }
        _open = Make();
        _open.Closed += (_, _) => _open = null;
        _open.Present();
    }

    public static ToolWindow Make()
    {
        var settings = Settings.Current;
        var window = new ToolWindow("Adawat Settings", 460);
        var stack = new StackPanel();
        void Section(string title) { stack.Children.Add(UI.Text(title, 12, FontWeight.SemiBold, Look.Muted).Pad(0, 6)); }
        void Save() => settings.Save();
        (ModifierKey, string)[] keys = [(ModifierKey.Shift, "Shift"), (ModifierKey.Ctrl, "Ctrl"), (ModifierKey.Alt, "Alt"), (ModifierKey.None, "None")];

        Section("Shortcuts while dragging");
        stack.Children.Add(UI.Row("Convert wheel", UI.Picker(keys, settings.ConvertKey, k => { settings.ConvertKey = k; Save(); })));
        stack.Children.Add(UI.Row("Tools wheel", UI.Picker(keys, settings.ToolsKey, k => { settings.ToolsKey = k; Save(); })));
        stack.Children.Add(UI.Row("Actions wheel", UI.Picker(keys, settings.ActionsKey, k => { settings.ActionsKey = k; Save(); })));
        stack.Children.Add(UI.Caption("Drag files anywhere, then press the key to open its wheel right away."));
        if (DesktopSupport.Note() is { } note) stack.Children.Add(note);
        stack.Children.Add(UI.Divider());

        Section("Results");
        stack.Children.Add(UI.Row("Save results", UI.Picker([(OutputLocation.NextToOriginal, "Next to the original"), (OutputLocation.Downloads, "Downloads folder"), (OutputLocation.Desktop, "Desktop")],
                                                             settings.OutputLocation, v => { settings.OutputLocation = v; Save(); })));
        stack.Children.Add(UI.Check("Show results in a Float", settings.ShowResultsInFloat, v => { settings.ShowResultsInFloat = v; Save(); }).Pad(0, 4));
        stack.Children.Add(UI.Check("Sound and haptic feedback", settings.PlaySounds, v => { settings.PlaySounds = v; Save(); }).Pad(0, 4));
        stack.Children.Add(UI.Divider());

        Section("Compression");
        stack.Children.Add(UI.Row("Default preset", UI.Segmented([(CompressPreset.Light, "Light"), (CompressPreset.Balanced, "Balanced"), (CompressPreset.Strong, "Strong")],
                                                                 settings.CompressPreset, v => { settings.CompressPreset = v; Save(); })));
        stack.Children.Add(UI.Row("Video", UI.Segmented([(VideoQuality.High, "High quality"), (VideoQuality.Balanced, "Balanced"), (VideoQuality.Small, "Smallest file")],
                                                        settings.VideoQuality, v => { settings.VideoQuality = v; Save(); })));
        stack.Children.Add(UI.Divider());

        Section("General");
        stack.Children.Add(UI.Check("Start Adawat when you sign in", Startup.IsEnabled, Startup.Set).Pad(0, 4));
        stack.Children.Add(UI.Check("Check for updates when Adawat starts", settings.CheckForUpdates, v => { settings.CheckForUpdates = v; Save(); }).Pad(0, 4));
        stack.Children.Add(UI.Row("Updates", UI.Button("Check Now", UpdateWindow.CheckNow)));
        var restart = UI.Button("Restart Now", Restart);
        restart.IsVisible = false;
        stack.Children.Add(UI.Row("Language", UI.Picker([("ar", "العربية"), ("en", "English")], settings.Language, v =>
        {
            settings.Language = v;
            Save();
            restart.IsVisible = v != (L10n.IsArabic ? "ar" : "en");
        })));
        var restartRow = new DockPanel { LastChildFill = false };
        var restartNote = UI.Caption("Adawat restarts to change the language.");
        DockPanel.SetDock(restart, Dock.Right);
        restartRow.Children.Add(restart);
        restartRow.Children.Add(restartNote);
        restart.PropertyChanged += (_, e) => { if (e.Property == Avalonia.Visual.IsVisibleProperty) restartNote.IsVisible = restart.IsVisible; };
        restartNote.IsVisible = false;
        stack.Children.Add(restartRow);
        var ffmpeg = ProcessRunner.Find("ffmpeg");
        stack.Children.Add(UI.Caption(ffmpeg != null ? $"ffmpeg: {ffmpeg}" : $"ffmpeg is not installed. Install it with: {Core.Desktop.Install("ffmpeg")}").Pad(0, 8));

        window.Body = stack;
        window.Leading(UI.Button("Restore Defaults", () =>
        {
            var defaults = new Settings();
            settings.ConvertKey = defaults.ConvertKey; settings.ToolsKey = defaults.ToolsKey; settings.ActionsKey = defaults.ActionsKey;
            settings.OutputLocation = defaults.OutputLocation; settings.ShowResultsInFloat = defaults.ShowResultsInFloat; settings.PlaySounds = defaults.PlaySounds;
            settings.CompressPreset = defaults.CompressPreset; settings.VideoQuality = defaults.VideoQuality;
            Save();
            window.Close();
            Present();
        }));
        window.Trailing(UI.Button("Close", window.Close, primary: true));
        return window;
    }

    /// <summary>Starts a fresh copy of the app and quits this one.</summary>
    public static void Restart()
    {
        var path = Environment.GetEnvironmentVariable("APPIMAGE") is { Length: > 0 } image ? image : Environment.ProcessPath!;
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = false });
        (Avalonia.Application.Current as AdawatApp)?.Quit();
    }
}

/// <summary>Starting at sign-in, through an XDG autostart entry (no administrator rights needed).</summary>
public static class Startup
{
    private static string Entry => Path.Combine(Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } c ? c : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config"),
                                                "autostart", "adawat.desktop");

    public static bool IsEnabled => File.Exists(Entry);

    public static void Set(bool enabled)
    {
        if (!enabled) { File.Delete(Entry); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(Entry)!);
        var exec = Environment.GetEnvironmentVariable("APPIMAGE") is { Length: > 0 } image ? image : Environment.ProcessPath!;
        File.WriteAllText(Entry, $"""
            [Desktop Entry]
            Type=Application
            Name=Adawat
            Comment=Convert, compress and edit any file while you drag it
            Exec="{exec}"
            Icon=adawat
            X-GNOME-Autostart-enabled=true
            NoDisplay=true

            """);
    }
}
