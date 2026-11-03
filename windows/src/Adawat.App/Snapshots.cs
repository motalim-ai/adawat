using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Adawat.App;

/// <summary>
/// Renders windows to PNG for checking builds and for the documentation, without showing them:
///   Adawat.exe --snapshot-window &lt;name&gt; &lt;out.png&gt; [files…] [--lang ar|en]
///   Adawat.exe --snapshot-wheel &lt;convert|tools|actions&gt; &lt;out.png&gt; &lt;files…&gt; [hovered index]
/// </summary>
public static class Snapshots
{
    public static int Run(Application app, string[] args)
    {
        var code = 1;
        app.Startup += (_, _) =>
        {
            try { code = Render(args); }
            catch (Exception e) { Console.Error.WriteLine(e); code = 1; }
            app.Shutdown(code);
        };
        app.Run();
        return code;
    }

    private static int Render(string[] args)
    {
        if (args.Length < 3) return 2;
        FrameworkElement? element = null;
        Window? window = null;
        if (args[0] == "--snapshot-window")
        {
            var name = args[1];
            var files = args.Skip(3).Select(Path.GetFullPath).ToList();
            window = name switch
            {
                "welcome0" or "welcome1" or "welcome2" or "welcome3" => WelcomeWindow.Make(name[^1] - '0'),
                "settings" => SettingsWindow.Make(),
                "update" => UpdateWindow.Make(new Core.Release(new(9, 9, 0), "Adawat 9.9.0\n\n- Arabic slides keep their line spacing in PDF.\n- أدوات يتحقق من التحديثات.", "Adawat-Setup-x64.exe", new("https://example.invalid"), "")),
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
        }
        if (window != null)
        {
            window.ShowActivated = false;
            window.Left = -20000;
            window.Show();
            element = (FrameworkElement)window.Content;
            Pump(TimeSpan.FromSeconds(2.5));
        }
        if (element == null) return 2;
        // A shown window is already laid out at its own width; a loose element is measured to fit its content.
        if (window == null)
        {
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            element.Arrange(new Rect(element.DesiredSize));
        }
        element.UpdateLayout();
        var width = (int)Math.Ceiling(window?.ActualWidth ?? element.ActualWidth);
        var height = (int)Math.Ceiling(window?.ActualHeight ?? element.ActualHeight);
        var bitmap = new RenderTargetBitmap(width * 2, height * 2, 192, 192, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(window?.Background ?? Brushes.Transparent, null, new Rect(0, 0, width, height));
            // A right-to-left window is mirrored where it meets the screen, so its content alone draws the other way round.
            var mirrored = window?.FlowDirection == FlowDirection.RightToLeft;
            if (mirrored) dc.PushTransform(new ScaleTransform(-1, 1, width / 2.0, 0));
            dc.DrawRectangle(new VisualBrush(element), null, new Rect(0, 0, width, height));
            if (mirrored) dc.Pop();
        }
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var stream = File.Create(args[2])) encoder.Save(stream);
        Console.WriteLine(Path.GetFullPath(args[2]));
        window?.Close();
        return 0;
    }

    /// <summary>Lets layout, image loading and background work settle.</summary>
    public static void Pump(TimeSpan time)
    {
        var frame = new System.Windows.Threading.DispatcherFrame();
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = time };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        System.Windows.Threading.Dispatcher.PushFrame(frame);
    }
}
