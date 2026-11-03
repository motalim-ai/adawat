using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Adawat.Core;
using H.NotifyIcon;

namespace Adawat.App;

/// <summary>The icon next to the clock and its menu, the counterpart of the Mac app's menu bar item.</summary>
public sealed class Tray : IDisposable
{
    private readonly TaskbarIcon _icon;

    public Tray()
    {
        var settings = Settings.Current;
        _icon = new TaskbarIcon
        {
            ToolTipText = L10n.T($"Drag files, then press {Key(settings.ConvertKey)}, {Key(settings.ToolsKey)} or {Key(settings.ActionsKey)}"),
            IconSource = new BitmapImage(new Uri("pack://application:,,,/Assets/Adawat.ico")),
            ContextMenu = Menu(),
            NoLeftClickDelay = true,
        };
        _icon.TrayLeftMouseUp += (_, _) => _icon.ContextMenu!.IsOpen = true;
        _icon.ForceCreate(enablesEfficiencyMode: false);
    }

    public static string Key(ModifierKey key) => key switch { ModifierKey.Shift => "Shift", ModifierKey.Ctrl => "Ctrl", ModifierKey.Alt => "Alt", _ => "—" };

    private static ContextMenu Menu()
    {
        var menu = new ContextMenu { FlowDirection = Theme.Direction, FontFamily = Theme.Font };
        MenuItem Item(string title, Action action, string? icon = null)
        {
            var item = new MenuItem { Header = L10n.T(title) };
            if (icon != null) item.Icon = new TextBlock { Text = icon, FontFamily = Theme.Icons, FontSize = 14 };
            item.Click += (_, _) => action();
            return item;
        }
        var hint = new MenuItem { Header = L10n.T("Adawat — drag files, then press a modifier key"), IsEnabled = false };
        menu.Items.Add(hint);
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("New Float", () => Floats.Create([]), ""));
        var closeFloats = Item("Close All Floats", Floats.CloseAll, "");
        menu.Items.Add(closeFloats);
        menu.Items.Add(Item("Create QR Code…", () => ToolWindows.Open("qr", []), ""));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Welcome Guide…", WelcomeWindow.Present, ""));
        menu.Items.Add(Item("Settings…", SettingsWindow.Present, ""));
        menu.Items.Add(Item("Check for Updates…", UpdateWindow.CheckNow, "\uE896"));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Exit Adawat", () => Application.Current.Shutdown(), ""));
        menu.Opened += (_, _) => closeFloats.IsEnabled = Floats.Any;
        return menu;
    }

    public void Dispose() => _icon.Dispose();
}
