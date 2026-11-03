using Avalonia.Controls;
using Adawat.Core;

namespace Adawat.Linux;

/// <summary>The icon in the top bar (or next to the clock) and its menu, the counterpart of the Mac app's menu bar item.
/// On GNOME it needs the AppIndicator extension, which Ubuntu turns on by default.</summary>
public sealed class Tray : IDisposable
{
    private readonly TrayIcon _icon;

    public Tray(AdawatApp app)
    {
        var settings = Settings.Current;
        _icon = new TrayIcon
        {
            Icon = AppIcon.Window,
            ToolTipText = L10n.T($"Drag files, then press {Key(settings.ConvertKey)}, {Key(settings.ToolsKey)} or {Key(settings.ActionsKey)}"),
            Menu = Menu(app),
            IsVisible = true,
        };
        TrayIcon.SetIcons(app, [_icon]);
    }

    public static string Key(ModifierKey key) => key switch { ModifierKey.Shift => "Shift", ModifierKey.Ctrl => "Ctrl", ModifierKey.Alt => "Alt", _ => "—" };

    private static NativeMenu Menu(AdawatApp app)
    {
        var menu = new NativeMenu();
        NativeMenuItem Item(string title, Action action)
        {
            var item = new NativeMenuItem(L10n.T(title));
            item.Click += (_, _) => action();
            return item;
        }
        menu.Items.Add(new NativeMenuItem(L10n.T("Adawat — drag files, then press a modifier key")) { IsEnabled = false });
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item("New Float", () => Floats.Create([])));
        var closeFloats = Item("Close All Floats", Floats.CloseAll);
        menu.Items.Add(closeFloats);
        menu.Items.Add(Item("Create QR Code…", () => ToolWindows.Open("qr", [])));
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item("Welcome Guide…", WelcomeWindow.Present));
        menu.Items.Add(Item("Settings…", SettingsWindow.Present));
        menu.Items.Add(Item("Check for Updates…", UpdateWindow.CheckNow));
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item("Quit Adawat", app.Quit));
        menu.Opening += (_, _) => closeFloats.IsEnabled = Floats.Any;
        return menu;
    }

    public void Dispose() => _icon.Dispose();
}
