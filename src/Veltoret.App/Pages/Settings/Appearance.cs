using System.Windows;
using System.Windows.Media;

namespace Veltoret.App.Pages.Settings;

/// <summary>"Pure black": swaps the page background brush (pages use {DynamicResource Brush.Background}).</summary>
public static class Appearance
{
    public static void Apply(bool oledBlack)
    {
        var app = Application.Current;
        if (app == null) return;
        var key = oledBlack ? "Color.BackgroundOled" : "Color.Background";
        var color = app.TryFindResource(key) is Color c ? c : oledBlack ? Colors.Black : Color.FromRgb(0x0B, 0x0B, 0x0D);
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        app.Resources["Brush.Background"] = brush;
    }
}
