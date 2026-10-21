using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Veltoret.App.Controls;

/// <summary>Indeterminate circular spinner (Material CircularProgressIndicator): a rotating 270° arc.</summary>
public sealed class Spinner : FrameworkElement
{
    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(nameof(Stroke), typeof(Brush), typeof(Spinner),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ThicknessProperty = DependencyProperty.Register(nameof(Thickness), typeof(double), typeof(Spinner),
        new FrameworkPropertyMetadata(2.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public Brush? Stroke { get => (Brush?)GetValue(StrokeProperty); set => SetValue(StrokeProperty, value); }
    public double Thickness { get => (double)GetValue(ThicknessProperty); set => SetValue(ThicknessProperty, value); }

    private readonly RotateTransform _rotate = new();

    public Spinner()
    {
        Width = 18;
        Height = 18;
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = _rotate;
        IsHitTestVisible = false;
        IsVisibleChanged += (_, _) => Update();
        Loaded += (_, _) => Update();
        Unloaded += (_, _) => _rotate.BeginAnimation(RotateTransform.AngleProperty, null);
    }

    private void Update()
    {
        if (IsVisible && IsLoaded)
            _rotate.BeginAnimation(RotateTransform.AngleProperty,
                new DoubleAnimation(0, 360, TimeSpan.FromMilliseconds(1000)) { RepeatBehavior = RepeatBehavior.Forever });
        else
            _rotate.BeginAnimation(RotateTransform.AngleProperty, null);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var brush = Stroke ?? (Brush)(TryFindResource("Brush.Amber") ?? Brushes.Orange);
        var t = Thickness;
        var r = Math.Max(0, Math.Min(ActualWidth, ActualHeight) / 2 - t / 2);
        if (r <= 0) return;
        var c = new Point(ActualWidth / 2, ActualHeight / 2);
        var start = new Point(c.X, c.Y - r);
        var angle = 270 * Math.PI / 180;
        var end = new Point(c.X + r * Math.Sin(angle), c.Y - r * Math.Cos(angle));
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(start, false, false);
            ctx.ArcTo(end, new Size(r, r), 0, true, SweepDirection.Clockwise, true, false);
        }
        g.Freeze();
        dc.DrawGeometry(null, new Pen(brush, t) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, g);
    }
}
