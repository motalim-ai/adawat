using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Adawat.Linux;

/// <summary>
/// Renders windows to PNG for checking builds and for the documentation, without showing them on screen:
///   adawat --snapshot-window &lt;name&gt; &lt;out.png&gt; [files…] [--lang ar|en]
///   adawat --snapshot-wheel &lt;convert|tools|actions&gt; &lt;out.png&gt; &lt;files…&gt; [hovered index]
/// </summary>
public static class Snapshots
{
    public static int ExitCode { get; private set; } = 1;

    public static async void Run(string[] arguments)
    {
        var args = arguments.Where((a, i) => a != "--lang" && (i == 0 || arguments[i - 1] != "--lang")).ToArray();
        try { ExitCode = await Render(args); }
        catch (Exception e) { Console.Error.WriteLine(e); ExitCode = 1; }
        (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown(ExitCode);
    }

    private static async Task<int> Render(string[] args)
    {
        if (args.Length < 3) return 2;
        Control? element = null;
        Window? window = null;
        if (args[0] == "--snapshot-window")
        {
            var name = args[1];
            var files = args.Skip(3).Select(Path.GetFullPath).ToList();
            window = name switch
            {
                "welcome0" or "welcome1" or "welcome2" or "welcome3" => WelcomeWindow.Make(name[^1] - '0'),
                "settings" => SettingsWindow.Make(),
                "update" => UpdateWindow.Make(new Core.Release(new(9, 9, 0), "Adawat 9.9.0\n\n- Arabic slides keep their line spacing in PDF.\n- أدوات يتحقق من التحديثات.", "Adawat-x86_64.AppImage", new("https://example.invalid"), "")),
                _ => ToolWindows.Make(name, files),
            };
            if (window == null) { Console.Error.WriteLine($"No window {name}. Known: {string.Join(" ", ToolWindows.Names)}"); return 2; }
        }
        else if (args[0] == "--snapshot-wheel")
        {
            var mode = Enum.Parse<Core.WheelMode>(args[1], true);
            var files = args.Skip(3).Where(a => !int.TryParse(a, out _)).Select(Path.GetFullPath).ToList();
            int? hovered = args.Skip(3).Select(a => int.TryParse(a, out var i) ? i : (int?)null).FirstOrDefault(i => i != null);
            element = Wheel.WheelPreview.Make(mode, files, hovered);
            // A loose control needs a window to lay out and load fonts in.
            window = new Window { Content = element, SizeToContent = SizeToContent.WidthAndHeight, Background = Avalonia.Media.Brushes.Transparent, WindowDecorations = WindowDecorations.None };
        }
        if (window == null) return 2;
        window.ShowActivated = false;
        window.ShowInTaskbar = false;
        window.Position = new PixelPoint(-20000, -20000);
        window.Show();
        await Task.Delay(2500);
        Dispatcher.UIThread.RunJobs();
        // The window's own size, at one pixel per unit: rendering at a higher DPI scales nested visuals twice in Avalonia 12.
        var size = window.ClientSize;
        const double scale = 1;
        using var bitmap = new RenderTargetBitmap(new PixelSize((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale)), new Vector(96 * scale, 96 * scale));
        bitmap.Render(window);
        bitmap.Save(args[2]);
        Console.WriteLine(Path.GetFullPath(args[2]));
        window.Close();
        return 0;
    }
}
