using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Veltoret.App.Controls;

namespace Veltoret.App.Pages.Onboarding;

/// <summary>Flat vector illustrations for onboarding (Android Illustrations.kt). No gradients.</summary>
public static class Illustrations
{
    private static readonly Color Cream = Color.FromRgb(0xF3, 0xE6, 0xCF);

    // bg, mid, dark, light, style
    private static readonly (string Bg, string Mid, string Dark, string Light, int Style)[] Palette =
    {
        ("#1F3B3A", "#2E5552", "#142726", "#E8A33D", 0),
        ("#3A2238", "#55304F", "#241522", "#F3E6CF", 1),
        ("#1E2A44", "#2C3D61", "#131B2C", "#F3C77F", 2),
        ("#4A2A1C", "#6B3D28", "#2E1A11", "#F3E6CF", 3),
        ("#2A2D35", "#3B3F4A", "#1A1C21", "#E8A33D", 4),
        ("#33361F", "#4A4F2D", "#202213", "#F3C77F", 1),
        ("#2B1F3D", "#3F2E58", "#1B1327", "#E8A33D", 0),
        ("#173238", "#214751", "#0F2125", "#F3E6CF", 2),
        ("#402024", "#5E2F35", "#281416", "#F3C77F", 4),
    };

    private static SolidColorBrush B(string hex) => (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
    private static SolidColorBrush B(Color c) => new(c);

    /// <summary>A 2:3 poster drawing (100×150 units, scaled to <paramref name="width"/>).</summary>
    public static FrameworkElement Poster(int index, double width, double radius = 8)
    {
        var p = Palette[((index % Palette.Length) + Palette.Length) % Palette.Length];
        var c = new Canvas { Width = 100, Height = 150, Background = B(p.Bg), ClipToBounds = true };
        switch (p.Style)
        {
            case 0: // sun over mountains
                c.Children.Add(At(new Ellipse { Width = 36, Height = 36, Fill = B(p.Light) }, 32, 34));
                c.Children.Add(new Polygon { Points = Pts("0,110 30,70 50,92 72,60 100,100 100,150 0,150"), Fill = B(p.Mid) });
                c.Children.Add(new Polygon { Points = Pts("0,124 40,96 70,118 100,104 100,150 0,150"), Fill = B(p.Dark) });
                break;
            case 1: // big moon + horizon
                c.Children.Add(At(new Ellipse { Width = 58, Height = 58, Fill = B(p.Light) }, 21, 30));
                c.Children.Add(At(new Rectangle { Width = 100, Height = 50, Fill = B(p.Mid) }, 0, 100));
                c.Children.Add(At(new Rectangle { Width = 100, Height = 4, Fill = B(p.Dark) }, 0, 98));
                break;
            case 2: // night skyline
                c.Children.Add(At(new Ellipse { Width = 14, Height = 14, Fill = B(p.Light) }, 70, 20));
                foreach (var (x, w, h) in new[] { (4, 16, 50), (22, 14, 70), (38, 20, 40), (60, 12, 64), (74, 22, 52) })
                    c.Children.Add(At(new Rectangle { Width = w, Height = h, Fill = B(p.Mid) }, x, 120 - h));
                c.Children.Add(At(new Rectangle { Width = 100, Height = 30, Fill = B(p.Dark) }, 0, 120));
                break;
            case 3: // overlapping discs
                c.Children.Add(At(new Ellipse { Width = 54, Height = 54, Fill = B(p.Mid) }, 12, 30));
                c.Children.Add(At(new Ellipse { Width = 54, Height = 54, Fill = B(p.Light), Opacity = 0.85 }, 34, 52));
                c.Children.Add(At(new Ellipse { Width = 30, Height = 30, Fill = B(p.Dark) }, 30, 70));
                break;
            default: // figure before the sun
                c.Children.Add(At(new Ellipse { Width = 60, Height = 60, Fill = B(p.Light) }, 20, 30));
                c.Children.Add(At(new Ellipse { Width = 12, Height = 12, Fill = B(p.Dark) }, 44, 52));
                c.Children.Add(new Polygon { Points = Pts("40,66 60,66 64,112 36,112"), Fill = B(p.Dark) });
                c.Children.Add(At(new Rectangle { Width = 100, Height = 38, Fill = B(p.Mid) }, 0, 112));
                break;
        }
        // Two cream "title lines" near the bottom.
        c.Children.Add(At(new Rectangle { Width = 56, Height = 5, RadiusX = 2.5, RadiusY = 2.5, Fill = B(Cream) }, 12, 128));
        c.Children.Add(At(new Rectangle { Width = 34, Height = 4, RadiusX = 2, RadiusY = 2, Fill = B(Cream), Opacity = 0.7 }, 12, 138));
        var vb = new Viewbox { Child = c, Stretch = Stretch.Fill, Width = width, Height = width * 1.5 };
        return new Border { CornerRadius = new CornerRadius(radius), Child = vb, ClipToBounds = true, Clip = new RectangleGeometry(new Rect(0, 0, width, width * 1.5), radius, radius) };
    }

    private static UIElement At(UIElement e, double x, double y)
    {
        Canvas.SetLeft(e, x);
        Canvas.SetTop(e, y);
        return e;
    }

    private static PointCollection Pts(string s) => PointCollection.Parse(s);

    /// <summary>Welcome: a wall of drifting posters behind a pulsing amber play disc.</summary>
    public static FrameworkElement PosterWall(double size)
    {
        var frame = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(28), Background = UiKit.Brush("Surface"),
            BorderBrush = UiKit.Brush("Outline"), BorderThickness = new Thickness(1), ClipToBounds = true,
        };
        var root = new Grid { ClipToBounds = true, Clip = new RectangleGeometry(new Rect(0, 0, size - 2, size - 2), 27, 27) };
        var cols = new Grid { Margin = new Thickness(10, 0, 10, 0) };
        var tileW = (size - 20 - 30) / 4;
        for (var i = 0; i < 4; i++)
        {
            cols.ColumnDefinitions.Add(new ColumnDefinition());
            var stack = new StackPanel { Width = tileW };
            for (var j = 0; j < 8; j++)
            {
                // Tiles repeat every 4 so the loop is seamless.
                var poster = Poster(i * 3 + j % 4, tileW);
                poster.Margin = new Thickness(0, 0, 0, 10);
                stack.Children.Add(poster);
            }
            var loopH = 4 * (tileW * 1.5 + 10);
            var t = new TranslateTransform();
            stack.RenderTransform = t;
            var up = i % 2 == 0;
            t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(up ? 0 : -loopH, up ? -loopH : 0, TimeSpan.FromSeconds(26)) { RepeatBehavior = RepeatBehavior.Forever });
            // A Canvas host: the column is taller than the frame and must not get layout-clipped.
            var host = new Canvas { Margin = new Thickness(5, 0, 5, 0) };
            Canvas.SetTop(stack, -tileW * 0.4);
            host.Children.Add(stack);
            Grid.SetColumn(host, i);
            cols.Children.Add(host);
        }
        root.Children.Add(cols);
        root.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x59, 0x0B, 0x0B, 0x0D)) });
        var center = new Grid { Width = 84, Height = 84, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var ring = new Ellipse { Width = 84, Height = 84, Stroke = UiKit.Brush("Amber"), StrokeThickness = 2, RenderTransformOrigin = new Point(0.5, 0.5) };
        var rs = new ScaleTransform();
        ring.RenderTransform = rs;
        var pulse = TimeSpan.FromSeconds(2.2);
        rs.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, 1.7, pulse) { RepeatBehavior = RepeatBehavior.Forever });
        rs.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, 1.7, pulse) { RepeatBehavior = RepeatBehavior.Forever });
        ring.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.6, 0, pulse) { RepeatBehavior = RepeatBehavior.Forever });
        center.Children.Add(ring);
        center.Children.Add(new Ellipse { Width = 76, Height = 76, Fill = UiKit.Brush("Amber") });
        var play = UiKit.Icon("Play", 42, "OnAmber");
        play.HorizontalAlignment = HorizontalAlignment.Center;
        play.Margin = new Thickness(4, 0, 0, 0);
        center.Children.Add(play);
        root.Children.Add(center);
        frame.Child = root;
        return frame;
    }

    /// <summary>Accounts: a PC ⇄ cloud with a dashed animated line and a lock / check badge.</summary>
    public static FrameworkElement Connect(bool connected)
    {
        var g = new Grid { Width = 420, Height = 210 };
        // PC
        var pc = new Border { Width = 132, Height = 92, CornerRadius = new CornerRadius(12), Background = UiKit.Brush("SurfaceHigh"), BorderBrush = UiKit.Brush("OutlineStrong"), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 16) };
        var minis = new UniformGrid2(2, 2, 6);
        for (var i = 0; i < 4; i++) minis.Add(Poster(i + 2, 22, 4));
        pc.Child = new Viewbox { Child = minis.Panel, Margin = new Thickness(14, 10, 14, 10) };
        g.Children.Add(pc);
        g.Children.Add(new Border { Width = 50, Height = 6, CornerRadius = new CornerRadius(3), Background = UiKit.Brush("OutlineStrong"), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(51, 108, 0, 0) });
        // Cloud
        var cloud = new Canvas { Width = 130, Height = 90, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        cloud.Children.Add(At(new Ellipse { Width = 60, Height = 60, Fill = UiKit.Brush("SurfaceHigh") }, 20, 10));
        cloud.Children.Add(At(new Ellipse { Width = 48, Height = 48, Fill = UiKit.Brush("SurfaceHigh") }, 62, 26));
        cloud.Children.Add(At(new Rectangle { Width = 100, Height = 34, RadiusX = 17, RadiusY = 17, Fill = UiKit.Brush("SurfaceHigh") }, 10, 46));
        cloud.Children.Add(new Polygon { Points = Pts("52,46 64,26 76,46"), Fill = UiKit.Brush("Amber") });
        cloud.Children.Add(new Polygon { Points = Pts("46,56 52,46 76,46 70,56"), Fill = UiKit.Brush("AmberSoft") });
        cloud.Children.Add(new Polygon { Points = Pts("64,26 70,16 82,36 76,46"), Fill = B(Cream) });
        g.Children.Add(cloud);
        // Dashed line
        var line = new Line { X1 = 150, X2 = 290, Y1 = 105, Y2 = 105, Stroke = UiKit.Brush(connected ? "Amber" : "OutlineStrong"), StrokeThickness = 2, StrokeDashArray = new DoubleCollection { 4, 4 } };
        line.BeginAnimation(Shape.StrokeDashOffsetProperty, new DoubleAnimation(0, -16, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever });
        g.Children.Add(line);
        // Badge
        var badge = new Grid { Width = 46, Height = 46, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransformOrigin = new Point(0.5, 0.5) };
        badge.Children.Add(new Ellipse { Fill = UiKit.Brush(connected ? "Amber" : "Surface"), Stroke = UiKit.Brush(connected ? "Amber" : "OutlineStrong"), StrokeThickness = 1 });
        var icon = UiKit.Icon(connected ? "Check" : "Lock", 22, connected ? "OnAmber" : "AmberSoft");
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        badge.Children.Add(icon);
        if (connected)
        {
            var s = new ScaleTransform(0.6, 0.6);
            badge.RenderTransform = s;
            var ease = new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut };
            s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(450)) { EasingFunction = ease });
            s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(450)) { EasingFunction = ease });
        }
        g.Children.Add(badge);
        return new Viewbox { Child = g, MaxWidth = 520, StretchDirection = StretchDirection.Both };
    }

    /// <summary>Folders: "Movies" and "TV Shows" folders with posters bobbing out.</summary>
    public static FrameworkElement Folders()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        row.Children.Add(Folder("Movies", "Movie", 0, 0));
        var second = Folder("TV Shows", "LiveTv", 4, 1.5);
        second.Margin = new Thickness(36, 0, 0, 0);
        row.Children.Add(second);
        return new Viewbox { Child = new Grid { Height = 200, Children = { row } }, MaxWidth = 460 };
    }

    private static FrameworkElement Folder(string label, string icon, int posterBase, double phase)
    {
        var col = new StackPanel();
        var g = new Grid { Width = 150, Height = 150 };
        // Posters peeking out (behind the front panel).
        var posters = new Canvas { Width = 150, Height = 150 };
        for (var i = 0; i < 2; i++)
        {
            var p = Poster(posterBase + i, 46, 5);
            Canvas.SetLeft(p, 30 + i * 46);
            Canvas.SetTop(p, 34);
            var t = new TranslateTransform();
            p.RenderTransform = t;
            t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, -14, TimeSpan.FromSeconds(1.5))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(phase + i * 0.4),
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            });
            posters.Children.Add(p);
        }
        g.Children.Add(new Border { Background = B("#6B4D22"), CornerRadius = new CornerRadius(12), Margin = new Thickness(6, 30, 6, 10) });
        g.Children.Add(new Border { Background = B("#6B4D22"), CornerRadius = new CornerRadius(8, 8, 0, 0), Width = 54, Height = 16, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(6, 18, 0, 0) });
        g.Children.Add(posters);
        var front = new Border { Background = UiKit.Brush("Amber"), CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 70, 0, 10) };
        var ic = UiKit.Icon(icon, 30, "OnAmber");
        ic.HorizontalAlignment = HorizontalAlignment.Center;
        front.Child = ic;
        g.Children.Add(front);
        col.Children.Add(g);
        var t2 = UiKit.Text(label, "Text.LabelLarge", "TextMuted");
        t2.HorizontalAlignment = HorizontalAlignment.Center;
        col.Children.Add(t2);
        return col;
    }

    /// <summary>TMDB step: three fanned posters swaying, a rating chip and a turning key disc.</summary>
    public static FrameworkElement Metadata()
    {
        var g = new Grid { Width = 340, Height = 210 };
        var fan = new Grid { Width = 200, Height = 200, HorizontalAlignment = HorizontalAlignment.Center, RenderTransformOrigin = new Point(0.5, 1) };
        for (var i = 0; i < 3; i++)
        {
            var p = Poster(i * 2 + 1, 92, 10);
            p.HorizontalAlignment = HorizontalAlignment.Center;
            p.VerticalAlignment = VerticalAlignment.Center;
            p.RenderTransformOrigin = new Point(0.5, 1);
            p.RenderTransform = new RotateTransform((i - 1) * 14);
            p.Margin = new Thickness((i - 1) * 70, 0, 0, 0);
            fan.Children.Add(p);
        }
        var sway = new RotateTransform();
        fan.RenderTransform = sway;
        sway.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-3, 3, TimeSpan.FromSeconds(1.3))
        {
            AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        });
        g.Children.Add(fan);
        var chip = new Border
        {
            CornerRadius = new CornerRadius(10), Background = UiKit.Brush("SurfaceHigh"), BorderBrush = UiKit.Brush("OutlineStrong"), BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 5, 10, 5), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 20, 10, 0),
            Child = UiKit.Text("★ 8.6", "Text.LabelLarge", "Amber", wrap: false),
        };
        g.Children.Add(chip);
        var key = new Grid { Width = 50, Height = 50, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(18, 0, 0, 14), RenderTransformOrigin = new Point(0.5, 0.5) };
        key.Children.Add(new Ellipse { Fill = UiKit.Brush("Amber") });
        var ki = UiKit.Icon("Key", 26, "OnAmber");
        ki.HorizontalAlignment = HorizontalAlignment.Center;
        key.Children.Add(ki);
        var rot = new RotateTransform();
        key.RenderTransform = rot;
        rot.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-20, 20, TimeSpan.FromSeconds(1.6))
        {
            AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        });
        g.Children.Add(key);
        return new Viewbox { Child = g, MaxWidth = 420 };
    }

    /// <summary>Scan: 4×2 poster slots revealed one by one, with an amber scan line until finished.</summary>
    public static FrameworkElement Scan(bool finished)
    {
        var frame = new Border
        {
            CornerRadius = new CornerRadius(24), Background = UiKit.Brush("Surface"), BorderBrush = UiKit.Brush("Outline"), BorderThickness = new Thickness(1),
            Padding = new Thickness(18), Width = 460,
        };
        var root = new Grid();
        var grid = new UniformGrid2(4, 2, 12);
        for (var i = 0; i < 8; i++)
        {
            var slot = new Grid();
            slot.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = UiKit.Brush("SurfaceHigh"), Width = 94, Height = 141 });
            var poster = Poster(i, 94, 8);
            if (!finished)
            {
                poster.Opacity = 0;
                var a = new DoubleAnimationUsingKeyFrames { Duration = TimeSpan.FromSeconds(4.8), RepeatBehavior = RepeatBehavior.Forever };
                var start = i * 0.5;
                a.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
                a.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(start))));
                a.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(start + 0.35))));
                a.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(4.5))));
                a.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(4.8))));
                poster.BeginAnimation(UIElement.OpacityProperty, a);
            }
            slot.Children.Add(poster);
            grid.Add(slot);
        }
        root.Children.Add(grid.Panel);
        if (!finished)
        {
            var line = new Border { Height = 2, Background = UiKit.Brush("Amber"), VerticalAlignment = VerticalAlignment.Top };
            var t = new TranslateTransform();
            line.RenderTransform = t;
            t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, 141 * 2 + 12, TimeSpan.FromSeconds(1.8))
            {
                AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            });
            root.Children.Add(line);
        }
        frame.Child = root;
        return new Viewbox { Child = frame, MaxWidth = 560 };
    }

    /// <summary>A fixed grid with gaps (children in row-major order).</summary>
    private sealed class UniformGrid2
    {
        private readonly int _cols;
        private readonly double _gap;
        public Grid Panel { get; } = new();
        private int _n;

        public UniformGrid2(int cols, int rows, double gap)
        {
            _cols = cols;
            _gap = gap;
            for (var c = 0; c < cols; c++) Panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            for (var r = 0; r < rows; r++) Panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }

        public void Add(FrameworkElement e)
        {
            var c = _n % _cols;
            var r = _n / _cols;
            e.Margin = new Thickness(c == 0 ? 0 : _gap, r == 0 ? 0 : _gap, 0, 0);
            Grid.SetColumn(e, c);
            Grid.SetRow(e, r);
            Panel.Children.Add(e);
            _n++;
        }
    }
}
