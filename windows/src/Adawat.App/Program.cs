using System.Windows;
using System.Windows.Markup;
using Adawat.App.Wheel;
using Adawat.Core;

namespace Adawat.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // Test and documentation modes render a window to a picture and exit; they never touch the running app.
        if (args.Length > 0 && args[0].StartsWith("--snapshot"))
        {
            var lang = Array.IndexOf(args, "--lang");
            if (lang >= 0 && lang + 1 < args.Length) L10n.Override(args[lang + 1]);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            return Snapshots.Run(app, args.Where((a, i) => a != "--lang" && (i == 0 || args[i - 1] != "--lang")).ToArray());
        }
        using var single = new Mutex(true, "Local\\Adawat.SingleInstance", out var first);
        if (!first) return 0;
        var main = new AdawatApp();
        return main.Run();
    }
}

/// <summary>The tray app: watches drags, shows the wheel, and owns the tray icon, Floats and tool windows.</summary>
public sealed class AdawatApp : Application
{
    private readonly DragMonitor _drags = new();
    private WheelWindow? _wheel;
    private Tray? _tray;

    public AdawatApp()
    {
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        DispatcherUnhandledException += (_, e) =>
        {
            Log.Write($"unhandled: {e.Exception}");
            Hud.Shared.ShowMessage(e.Exception.Message, Hud.Style.Failure);
            e.Handled = true;
        };
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(XmlLanguage.GetLanguage(L10n.IsArabic ? "ar" : "en-US")));
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Log.Write($"started {typeof(AdawatApp).Assembly.GetName().Version} on {Environment.OSVersion}");
        _wheel = new WheelWindow();
        _drags.KeyDuringDrag += (key, point) =>
        {
            var settings = Settings.Current;
            WheelMode? mode = key == settings.ConvertKey ? WheelMode.Convert : key == settings.ToolsKey ? WheelMode.Tools : key == settings.ActionsKey ? WheelMode.Actions : null;
            if (mode is { } m) _wheel.Show(m, point);
        };
        _drags.DragEnded += () =>
        {
            // The drop handler runs before the button-up is seen; a short delay lets it finish first.
            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            timer.Tick += (_, _) => { timer.Stop(); if (!Native.IsDown(Native.VK_LBUTTON)) _wheel.HideWheel(); };
            timer.Start();
        };
        _drags.Start();
        FileActions.FloatHandler = files => { Floats.Create(files); return Task.CompletedTask; };
        FileActions.ShareHandler = files => { Dispatcher.Invoke(() => ShareUI.Share(files)); return Task.CompletedTask; };
        FileActions.ChooseFolder = files => Task.FromResult(Dispatcher.Invoke(() =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = L10n.T($"Choose where to move {(files.Count == 1 ? Path.GetFileName(files[0]) : L10n.T($"{files.Count} items"))}") };
            return dialog.ShowDialog() == true ? dialog.FolderName : null;
        }));
        _tray = new Tray();
        if (!Settings.Current.HasSeenWelcome) WelcomeWindow.Present();
        else UpdateWindow.CheckAtStart();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _drags.Dispose();
        _tray?.Dispose();
        base.OnExit(e);
    }
}
