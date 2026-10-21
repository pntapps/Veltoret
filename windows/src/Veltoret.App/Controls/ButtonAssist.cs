using System.Windows;
using System.Windows.Media;

namespace Veltoret.App.Controls;

/// <summary>
/// Attached properties the shared button/chip/text-box styles read (Themes/Controls.xaml):
/// <c>c:ButtonAssist.Icon="{StaticResource Icon.Play}"</c> shows a 20 px icon before the label,
/// <c>c:ButtonAssist.IsLoading="True"</c> replaces it with a spinner and blocks clicks,
/// <c>c:ButtonAssist.Placeholder</c> is the hint text of a TextBox / PasswordBox.
/// </summary>
public static class ButtonAssist
{
    public static readonly DependencyProperty IconProperty = DependencyProperty.RegisterAttached(
        "Icon", typeof(Geometry), typeof(ButtonAssist), new PropertyMetadata(null));

    public static Geometry? GetIcon(DependencyObject o) => (Geometry?)o.GetValue(IconProperty);
    public static void SetIcon(DependencyObject o, Geometry? v) => o.SetValue(IconProperty, v);

    public static readonly DependencyProperty IsLoadingProperty = DependencyProperty.RegisterAttached(
        "IsLoading", typeof(bool), typeof(ButtonAssist), new PropertyMetadata(false));

    public static bool GetIsLoading(DependencyObject o) => (bool)o.GetValue(IsLoadingProperty);
    public static void SetIsLoading(DependencyObject o, bool v) => o.SetValue(IsLoadingProperty, v);

    public static readonly DependencyProperty PlaceholderProperty = DependencyProperty.RegisterAttached(
        "Placeholder", typeof(string), typeof(ButtonAssist), new PropertyMetadata(null));

    public static string? GetPlaceholder(DependencyObject o) => (string?)o.GetValue(PlaceholderProperty);
    public static void SetPlaceholder(DependencyObject o, string? v) => o.SetValue(PlaceholderProperty, v);

    /// <summary>Icon size for Button.Icon (default 50% of the button).</summary>
    public static readonly DependencyProperty IconSizeProperty = DependencyProperty.RegisterAttached(
        "IconSize", typeof(double), typeof(ButtonAssist), new PropertyMetadata(20.0));

    public static double GetIconSize(DependencyObject o) => (double)o.GetValue(IconSizeProperty);
    public static void SetIconSize(DependencyObject o, double v) => o.SetValue(IconSizeProperty, v);

    /// <summary>PasswordBox has no bindable "is empty"; the style's placeholder watches this.</summary>
    public static readonly DependencyProperty IsEmptyProperty = DependencyProperty.RegisterAttached(
        "IsEmpty", typeof(bool), typeof(ButtonAssist), new PropertyMetadata(true));

    public static bool GetIsEmpty(DependencyObject o) => (bool)o.GetValue(IsEmptyProperty);
    public static void SetIsEmpty(DependencyObject o, bool v) => o.SetValue(IsEmptyProperty, v);

    /// <summary>Set by the PasswordBox style so <see cref="IsEmptyProperty"/> tracks the password.</summary>
    public static readonly DependencyProperty TrackPasswordProperty = DependencyProperty.RegisterAttached(
        "TrackPassword", typeof(bool), typeof(ButtonAssist), new PropertyMetadata(false, (o, e) =>
        {
            if (o is System.Windows.Controls.PasswordBox pb && (bool)e.NewValue)
            {
                pb.PasswordChanged -= OnPasswordChanged;
                pb.PasswordChanged += OnPasswordChanged;
                SetIsEmpty(pb, pb.Password.Length == 0);
            }
        }));

    public static bool GetTrackPassword(DependencyObject o) => (bool)o.GetValue(TrackPasswordProperty);
    public static void SetTrackPassword(DependencyObject o, bool v) => o.SetValue(TrackPasswordProperty, v);

    private static void OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        var pb = (System.Windows.Controls.PasswordBox)sender;
        SetIsEmpty(pb, pb.Password.Length == 0);
    }
}
