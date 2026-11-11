using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Adawat.Core;
using Adawat.Linux.Desktop;

namespace Adawat.Linux;

/// <summary>A small toast at the top of the screen that says what Adawat is doing: working (with progress), done, cancelled
/// or failed. Clicks pass through it, except on the Cancel button it offers for the work in progress.</summary>
public sealed class Hud : Window
{
    public enum Style { Working, Success, Failure, Cancelled }

    private static Hud? _shared;
    public static Hud Shared => _shared ??= new Hud();

    private readonly TextBlock _icon = new() { FontFamily = Look.Icons, FontSize = 17, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _text = new() { FontFamily = Look.Font, FontSize = 12.5, FontWeight = FontWeight.Medium, Foreground = Look.Ink, TextWrapping = TextWrapping.Wrap, MaxWidth = 340, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _percent = new() { FontFamily = Look.Font, FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = Look.Muted, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar _bar = new() { Height = 4, MinHeight = 4, Minimum = 0, Maximum = 1, Foreground = Look.Accent, Background = Look.ButtonFill, Margin = new Thickness(0, 6, 0, 0), IsVisible = false };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(2.6) };
    private readonly SoftButton _cancel;
    private Action? _onCancel;
    private PixelRect? _clickable;
    private Style _style;

    private Hud()
    {
        WindowDecorations = WindowDecorations.None;
        TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        Background = Look.Clear;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        CanResize = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        FlowDirection = Look.Direction;
        Title = "Adawat";
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9 };
        row.Children.Add(_icon);
        row.Children.Add(_text);
        row.Children.Add(_percent);
        _cancel = UI.IconButton("\uE711", CancelClicked, "Cancel");
        _cancel.Margin = new Thickness(1, -5, -6, -5);
        _cancel.IsVisible = false;
        row.Children.Add(_cancel);
        var column = new StackPanel();
        column.Children.Add(row);
        column.Children.Add(_bar);
        Content = new Border
        {
            Margin = new Thickness(18), Padding = new Thickness(14, 9), CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(0xF5, 0xFF, 0xFF, 0xFF)), BorderBrush = Look.Hairline, BorderThickness = new Thickness(1),
            BoxShadow = Look.Shadow(18, 4, 0.16), Child = column,
        };
        Transitions = [new Avalonia.Animation.DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(220) }];
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); Fade(); };
        Desktop.X11Window.SkipWindowManager(this);
        Opened += (_, _) => { _clickable = null; ShapeClicks(); };
        LayoutUpdated += (_, _) => ShapeClicks();
        SizeChanged += (_, _) => Place();
    }

    /// <summary><paramref name="cancel"/>, for work in progress, adds a Cancel button that calls it.</summary>
    public void ShowMessage(string text, Style style, Action? cancel = null)
    {
        _style = style;
        _text.Text = L10n.T(text);
        _icon.Text = Icons.Glyph(style switch { Style.Working => "", Style.Success => "", Style.Cancelled => "\uE711", _ => "" });
        _icon.Foreground = style switch { Style.Failure => Look.Failure, Style.Cancelled => Look.Muted, _ => Look.Accent };
        _onCancel = style == Style.Working ? cancel : null;
        _cancel.IsVisible = _onCancel != null;
        _bar.IsVisible = false;
        _percent.Text = "";
        if (style == Style.Working) _hideTimer.Stop(); else { _hideTimer.Interval = TimeSpan.FromSeconds(style == Style.Failure ? 4 : 2.6); _hideTimer.Start(); }
        Opacity = 1;
        if (!IsVisible) Show();
        Place();
    }

    public void Update(string text)
    {
        if (_style != Style.Working) return;
        _text.Text = L10n.T(text);
    }

    public void SetProgress(double fraction)
    {
        if (_style != Style.Working) return;
        _bar.IsVisible = true;
        _bar.Value = fraction;
        _percent.Text = $"{(int)Math.Round(fraction * 100)}%";
    }

    private void CancelClicked()
    {
        var cancel = _onCancel;
        _onCancel = null;
        _cancel.IsVisible = false;
        cancel?.Invoke();
    }

    /// <summary>Keeps the X11 input shape on the Cancel button, wherever the layout puts it, and empty without one.</summary>
    private void ShapeClicks()
    {
        var area = default(PixelRect);
        if (_cancel.IsVisible)
        {
            // Through the screen, so the rectangle is right in Arabic too, where the row is mirrored.
            var a = _cancel.PointToScreen(default);
            var b = _cancel.PointToScreen(new Point(_cancel.Bounds.Width, _cancel.Bounds.Height));
            area = new PixelRect(Math.Min(a.X, b.X) - Position.X, Math.Min(a.Y, b.Y) - Position.Y, Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));
        }
        if (area == _clickable) return;
        _clickable = area;
        if (area.Width > 0 && area.Height > 0) Desktop.X11Window.ClickOnly(this, area.X, area.Y, area.Width, area.Height);
        else Desktop.X11Window.ClickThrough(this);
    }

    private void Fade()
    {
        Opacity = 0;
        DispatcherTimer.RunOnce(() => { if (Opacity == 0) Hide(); }, TimeSpan.FromMilliseconds(260));
    }

    /// <summary>Top centre of the screen with the pointer (the primary screen when the pointer is unknown).</summary>
    private void Place()
    {
        var screen = Screens.ScreenFromPoint(LastPointer.Position) ?? Screens.Primary;
        if (screen == null) return;
        var work = screen.WorkingArea;
        var width = (int)(Bounds.Width * screen.Scaling);
        Position = new PixelPoint(work.X + (work.Width - width) / 2, work.Y + 6);
    }
}
