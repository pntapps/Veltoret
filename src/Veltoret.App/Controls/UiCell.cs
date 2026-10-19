using System.Windows;
using System.Windows.Controls;

namespace Veltoret.App.Controls;

/// <summary>
/// A grid cell built in code: <see cref="VirtualGrid"/> shows it through <see cref="UiCellHost"/>, which calls
/// <see cref="Build"/> whenever the (recycled) cell is bound to it. <see cref="Key"/> gives value equality.
/// </summary>
public sealed record UiCell(object Key, Func<FrameworkElement> Build)
{
    public bool Equals(UiCell? other) => other != null && Equals(Key, other.Key);
    public override int GetHashCode() => Key.GetHashCode();
}

public sealed class UiCellHost : ContentControl
{
    public UiCellHost()
    {
        Focusable = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        DataContextChanged += (_, e) => Content = e.NewValue is UiCell c ? c.Build() : null;
    }
}
