using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace Veltoret.App.Controls;

/// <summary>
/// A Material Rounded-style icon drawn from a 24×24 geometry (resources "Icon.*" in Themes/Controls.xaml).
/// The fill follows the inherited Foreground unless <see cref="Fill"/> is set.
/// <c>&lt;c:Icon Data="{StaticResource Icon.Search}" Size="20" /&gt;</c>
/// </summary>
public sealed class Icon : FrameworkElement
{
    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(nameof(Data), typeof(Geometry), typeof(Icon),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(nameof(Size), typeof(double), typeof(Icon),
        new FrameworkPropertyMetadata(24.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(nameof(Fill), typeof(Brush), typeof(Icon),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ForegroundProperty = TextElement.ForegroundProperty.AddOwner(typeof(Icon),
        new FrameworkPropertyMetadata(Brushes.White, FrameworkPropertyMetadataOptions.Inherits | FrameworkPropertyMetadataOptions.AffectsRender));

    public Geometry? Data { get => (Geometry?)GetValue(DataProperty); set => SetValue(DataProperty, value); }
    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }
    public Brush? Fill { get => (Brush?)GetValue(FillProperty); set => SetValue(FillProperty, value); }
    public Brush Foreground { get => (Brush)GetValue(ForegroundProperty); set => SetValue(ForegroundProperty, value); }

    public Icon()
    {
        SnapsToDevicePixels = true;
        IsHitTestVisible = false;
    }

    protected override Size MeasureOverride(Size availableSize) => new(Size, Size);

    protected override void OnRender(DrawingContext dc)
    {
        if (Data == null) return;
        var s = Size / 24.0;
        dc.PushTransform(new ScaleTransform(s, s));
        dc.DrawGeometry(Fill ?? Foreground, null, Data);
        dc.Pop();
    }

    /// <summary>Looks up "Icon.{name}" from the application resources.</summary>
    public static Geometry? Get(string name) => Application.Current?.TryFindResource("Icon." + name) as Geometry;
}
