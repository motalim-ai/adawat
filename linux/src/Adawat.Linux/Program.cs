using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;
using Adawat.Core;
using Adawat.Linux.Desktop;
using Adawat.Linux.Wheel;

[assembly: System.Runtime.Versioning.SupportedOSPlatform("linux")]

namespace Adawat.Linux;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] is "--help" or "-h")
        {
            Console.WriteLine("usage: adawat                 start Adawat in the top bar\n" +
                              "       adawat --wheel FILE…   open the wheel for these files (the file manager's Open with Adawat)\n" +
                              "       adawat --version");
            return 0;
        }
        if (args.Length > 0 && args[0] == "--version")
        {
            Console.WriteLine($"Adawat {typeof(Program).Assembly.GetName().Version?.ToString(3)}");
            return 0;
        }
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY")) && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")))
        {
            Console.Error.WriteLine("Adawat needs a desktop session. For the command line, use adawat-cli.");
            return 1;
        }
        var lang = Array.IndexOf(args, "--lang");
        if (lang >= 0 && lang + 1 < args.Length) L10n.Override(args[lang + 1]);
        // Test and documentation modes render a window to a picture and exit; they never touch the running app.
        if (args.Length > 0 && args[0].StartsWith("--snapshot"))
        {
            BuildApp().StartWithClassicDesktopLifetime(args, ShutdownMode.OnExplicitShutdown);
            return Snapshots.ExitCode;
        }
        // "adawat --wheel FILE…" opens the wheel for files picked in a file manager (its "Open with Adawat" menu item).
        if (args.Length > 0 && args[0] == "--wheel" && Instance.Forward(args.Skip(1).Select(Path.GetFullPath).ToList())) return 0;
        using var single = new Mutex(true, "Adawat.SingleInstance", out var first);
        if (!first) return 0;
        // A failure while starting is written to the log and ends the app quietly, instead of an abort that the desktop
        // reports as a crash.
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"unhandled: {e.ExceptionObject}");
        try
        {
            return BuildApp().StartWithClassicDesktopLifetime(args, ShutdownMode.OnExplicitShutdown);
        }
        catch (Exception e)
        {
            Log.Write($"could not start: {e}");
            Console.Error.WriteLine($"Adawat could not start: {e.Message}");
            return 1;
        }
    }

    public static AppBuilder BuildApp() => AppBuilder.Configure<AdawatApp>()
        .UsePlatformDetect()
        // Software rendering: with OpenGL, Xwayland holds each frame until GNOME signals the last one was shown, which it
        // stops doing during a drag, so the wheel would redraw about once a second exactly when it matters.
        .With(new X11PlatformOptions { EnableIme = false, RenderingMode = [X11RenderingMode.Software] })
        .LogToTrace();
}

/// <summary>The tray app: watches drags, shows the wheel, and owns the tray icon, Floats and tool windows.</summary>
public sealed class AdawatApp : Application
{
    private IDragWatch? _drags;
    private WheelWindow? _wheel;
    private Tray? _tray;

    public override void Initialize()
    {
        // Fluent's controls (sliders, check boxes, progress) take the app's violet instead of their default blue.
        var fluent = new FluentTheme();
        fluent.Palettes[Avalonia.Styling.ThemeVariant.Light] = new Avalonia.Themes.Fluent.ColorPaletteResources { Accent = Look.AccentColor };
        Styles.Add(fluent);
        RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Light;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        base.OnFrameworkInitializationCompleted();
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            Log.Write($"unhandled: {e.Exception}");
            Hud.Shared.ShowMessage(e.Exception.Message, Hud.Style.Failure);
            e.Handled = true;
        };
        if (Environment.GetCommandLineArgs().Skip(1).FirstOrDefault()?.StartsWith("--snapshot") == true)
        {
            Snapshots.Run(Environment.GetCommandLineArgs().Skip(1).ToArray());
            return;
        }
        Log.Write($"started {typeof(AdawatApp).Assembly.GetName().Version} on {Environment.OSVersion} · {Core.Desktop.Name} · {(Core.Desktop.IsWayland ? "Wayland" : "X11")}");
        Core.Clipboard.Host = new ClipboardHost();
        _wheel = new WheelWindow();
        _wheel.Park();
        _drags = DragWatch.ForSession();
        if (_drags != null)
        {
            _drags.KeyDuringDrag += (key, point) =>
            {
                var settings = Settings.Current;
                WheelMode? mode = key == settings.ConvertKey ? WheelMode.Convert : key == settings.ToolsKey ? WheelMode.Tools : key == settings.ActionsKey ? WheelMode.Actions : null;
                if (mode is { } m) _wheel.Show(m, point);
            };
            _drags.DragEnded += () =>
            {
                // The drop handler runs before the button-up is seen; a short delay lets it finish first.
                DispatcherTimer.RunOnce(() => { if (!_drags.ButtonDown) _wheel.HideWheel(); }, TimeSpan.FromMilliseconds(150));
            };
            try { _drags.Start(); }
            catch (Exception e) { Log.Write($"drag watch failed: {e}"); }
        }
        Instance.Listen(files => FileWheel.Present(files));
        FileActions.FloatHandler = files => { Dispatcher.UIThread.Post(() => Floats.Create(files)); return Task.CompletedTask; };
        FileActions.ShareHandler = files => { Dispatcher.UIThread.Post(() => ShareWindow.Present(files)); return Task.CompletedTask; };
        FileActions.ChooseFolder = files => Dispatcher.UIThread.InvokeAsync(() => Folders.Choose(files));
        _tray = new Tray(this);
        Task.Run(ShellExtension.EnsureInstalled);
        Task.Run(FileManagers.Install);
        if (!Settings.Current.HasSeenWelcome) WelcomeWindow.Present();
        else UpdateWindow.CheckAtStart();
    }

    public void Quit()
    {
        _drags?.Dispose();
        _tray?.Dispose();
        Instance.Stop();
        (ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }
}
