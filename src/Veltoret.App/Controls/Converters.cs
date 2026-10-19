using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Veltoret.App.Controls;

/// <summary>Small value converters used by the shared styles and pages.</summary>
public static class Converters
{
    public static readonly IValueConverter NotNull = new Fn(v => v != null);
    public static readonly IValueConverter HalfRadius = new Fn(v => new CornerRadius(v is double d ? d / 2 : 0));
    public static readonly IValueConverter VisibleIfTrue = new Fn(v => v is true ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter VisibleIfFalse = new Fn(v => v is true ? Visibility.Collapsed : Visibility.Visible);
    public static readonly IValueConverter VisibleIfNotNull = new Fn(v =>
        v == null || v is string { Length: 0 } ? Visibility.Collapsed : Visibility.Visible);
    public static readonly IValueConverter VisibleIfNull = new Fn(v =>
        v == null || v is string { Length: 0 } ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter VisibleIfPositive = new Fn(v =>
        v is double d && d > 0 || v is float f && f > 0 || v is int i && i > 0 ? Visibility.Visible : Visibility.Collapsed);
    public static readonly IValueConverter Upper = new Fn(v => v?.ToString()?.ToUpperInvariant());
    public static readonly IValueConverter Not = new Fn(v => v is not true);

    private sealed class Fn(Func<object?, object?> f) : IValueConverter
    {
        public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => f(value);
        public object? ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
    }
}
