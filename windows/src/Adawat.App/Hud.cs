using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Adawat.Core;

namespace Adawat.App;

/// <summary>A small toast at the top of the screen that says what Adawat is doing: working (with progress), done, cancelled
/// or failed. Clicks pass through it, except while it offers Cancel for the work in progress.</summary>
public sealed class Hud : Window
{
    public enum Style { Working, Success, Failure, Cancelled }

    public static Hud Shared { get; } = new();

    private readonly TextBlock _icon = new() { FontFamily = Theme.Icons, FontSize = 15, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _text = new() { FontFamily = Theme.Font, FontSize = 12.5, FontWeight = FontWeights.Medium, Foreground = Theme.Ink, TextWrapping = TextWrapping.Wrap, MaxWidth = 340, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _percent = new() { FontFamily = Theme.Font, FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = Theme.Muted, Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar _bar = new() { Height = 4, Minimum = 0, Maximum = 1, Foreground = Theme.Accent, Background = Theme.ButtonFill, BorderThickness = new Thickness(0), Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(2.6) };
    private readonly Button _cancel;
    private Action? _onCancel;
    private IntPtr _handle;
    private Style _style;

    private Hud()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        FlowDirection = Theme.Direction;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_icon);
        row.Children.Add(new Border { Width = 9 });
        row.Children.Add(_text);
        row.Children.Add(_percent);
        _cancel = UI.IconButton("\uE711", CancelClicked, "Cancel");
        _cancel.Margin = new Thickness(10, -5, -6, -5);
        _cancel.Visibility = Visibility.Collapsed;
        row.Children.Add(_cancel);
        var column = new StackPanel();
        column.Children.Add(row);
        column.Children.Add(_bar);
        Content = new Border
        {
            Margin = new Thickness(18), Padding = new Thickness(14, 9, 14, 9), CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(Color.FromArgb(0xF5, 0xFF, 0xFF, 0xFF)), BorderBrush = Theme.Hairline, BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Direction = 270, Opacity = 0.16 }, Child = column,
        };
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); Fade(); };
        SourceInitialized += (_, _) =>
        {
            _handle = new WindowInteropHelper(this).Handle;
            Native.MakeToolWindow(_handle, clickThrough: _onCancel == null);
        };
        SizeChanged += (_, _) => Position();
    }

    /// <summary><paramref name="cancel"/>, for work in progress, adds a Cancel button that calls it.</summary>
    public void ShowMessage(string text, Style style, Action? cancel = null)
    {
        _style = style;
        _text.Text = L10n.T(text);
        _icon.Text = style switch { Style.Working => "", Style.Success => "", Style.Cancelled => "\uE711", _ => "" };
        _icon.Foreground = style switch { Style.Failure => new SolidColorBrush(Color.FromRgb(0xD8, 0x3B, 0x3B)), Style.Cancelled => Theme.Muted, _ => Theme.Accent };
        OfferCancel(style == Style.Working ? cancel : null);
        _bar.Visibility = Visibility.Collapsed;
        _percent.Text = "";
        if (style == Style.Working) _hideTimer.Stop(); else { _hideTimer.Interval = TimeSpan.FromSeconds(style == Style.Failure ? 4 : 2.6); _hideTimer.Start(); }
        BeginAnimation(OpacityProperty, null);
        Opacity = 1;
        if (!IsVisible) Show();
        Position();
    }

    public void Update(string text)
    {
        if (_style != Style.Working) return;
        _text.Text = L10n.T(text);
    }

    public void SetProgress(double fraction)
    {
        if (_style != Style.Working) return;
        _bar.Visibility = Visibility.Visible;
        _bar.Value = fraction;
        _percent.Text = $"{(int)Math.Round(fraction * 100)}%";
    }

    /// <summary>Shows or hides the Cancel button. The toast takes clicks only while the button is there.</summary>
    private void OfferCancel(Action? cancel)
    {
        _onCancel = cancel;
        _cancel.Visibility = cancel != null ? Visibility.Visible : Visibility.Collapsed;
        if (_handle != IntPtr.Zero) Native.MakeToolWindow(_handle, clickThrough: cancel == null);
    }

    private void CancelClicked()
    {
        var cancel = _onCancel;
        OfferCancel(null);
        cancel?.Invoke();
    }

    private void Fade()
    {
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(220));
        fade.Completed += (_, _) => { if (Opacity == 0) Hide(); };
        BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>Top centre of the screen with the pointer.</summary>
    private void Position()
    {
        Native.GetCursorPos(out var point);
        var work = Native.WorkArea(point.X, point.Y);
        var scale = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1;
        Left = (work.Left + (work.Right - work.Left) / 2.0) / scale - ActualWidth / 2;
        Top = work.Top / scale + 6;
    }
}
