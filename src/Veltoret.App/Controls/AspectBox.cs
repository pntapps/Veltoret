using System.Windows;
using System.Windows.Controls;

namespace Veltoret.App.Controls;

/// <summary>Sizes its child to the available width and <c>width × Ratio</c> height (posters 1.5, 16:9 = 0.5625).</summary>
public sealed class AspectBox : Decorator
{
    public static readonly DependencyProperty RatioProperty = DependencyProperty.Register(nameof(Ratio), typeof(double), typeof(AspectBox),
        new FrameworkPropertyMetadata(1.5, FrameworkPropertyMetadataOptions.AffectsMeasure));

    /// <summary>Height ÷ width.</summary>
    public double Ratio { get => (double)GetValue(RatioProperty); set => SetValue(RatioProperty, value); }

    protected override Size MeasureOverride(Size constraint)
    {
        var w = double.IsInfinity(constraint.Width) ? (double.IsNaN(Width) ? 160 : Width) : constraint.Width;
        var h = w * Ratio;
        if (!double.IsInfinity(constraint.Height) && h > constraint.Height && double.IsInfinity(constraint.Width))
        {
            h = constraint.Height;
            w = h / Ratio;
        }
        Child?.Measure(new Size(w, h));
        return new Size(w, h);
    }

    protected override Size ArrangeOverride(Size arrangeSize)
    {
        var w = arrangeSize.Width;
        var h = w * Ratio;
        Child?.Arrange(new Rect(0, 0, w, h));
        return new Size(w, h);
    }
}
