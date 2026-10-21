using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using Veltoret.App.Services;

namespace Veltoret.App.Controls;

/// <summary>
/// VImage: loads <see cref="Url"/> through <c>AppServices.Images</c> (disk cache, works offline), decoded off the
/// UI thread at <see cref="DecodeWidth"/>. While loading it shows a flat SurfaceHigh placeholder that breathes
/// (opacity 0.55↔1, 900 ms); with no URL it shows <see cref="FallbackText"/> centered in serif. Crop scaling,
/// rounded by <see cref="Border.CornerRadius"/> (content is clipped to it).
/// </summary>
public class AsyncImage : Border
{
    public static readonly DependencyProperty UrlProperty = DependencyProperty.Register(nameof(Url), typeof(string), typeof(AsyncImage),
        new PropertyMetadata(null, (d, _) => ((AsyncImage)d).Reload()));

    public static readonly DependencyProperty FallbackTextProperty = DependencyProperty.Register(nameof(FallbackText), typeof(string), typeof(AsyncImage),
        new PropertyMetadata(null, (d, e) => ((AsyncImage)d)._fallback.Text = (string?)e.NewValue ?? ""));

    public static readonly DependencyProperty DecodeWidthProperty = DependencyProperty.Register(nameof(DecodeWidth), typeof(int), typeof(AsyncImage),
        new PropertyMetadata(0));

    public static readonly DependencyProperty StretchProperty = DependencyProperty.Register(nameof(Stretch), typeof(Stretch), typeof(AsyncImage),
        new PropertyMetadata(Stretch.UniformToFill, (d, e) => ((AsyncImage)d)._image.Stretch = (Stretch)e.NewValue));

    public string? Url { get => (string?)GetValue(UrlProperty); set => SetValue(UrlProperty, value); }
    public string? FallbackText { get => (string?)GetValue(FallbackTextProperty); set => SetValue(FallbackTextProperty, value); }
    /// <summary>Decode to this many pixels wide (0 = the image's own size). Saves memory in long grids.</summary>
    public int DecodeWidth { get => (int)GetValue(DecodeWidthProperty); set => SetValue(DecodeWidthProperty, value); }
    public Stretch Stretch { get => (Stretch)GetValue(StretchProperty); set => SetValue(StretchProperty, value); }

    private readonly Grid _root = new() { ClipToBounds = true };
    private readonly Border _placeholder;
    private readonly TextBlock _fallback;
    private readonly Image _image = new() { Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private CancellationTokenSource? _cts;
    private bool _pulsing;

    // Small in-memory cache of decoded bitmaps so virtualized rows don't re-decode while scrolling.
    private static readonly LinkedList<(string Key, BitmapSource Bitmap)> Lru = new();
    private static readonly Dictionary<string, LinkedListNode<(string Key, BitmapSource Bitmap)>> LruIndex = new();
    private const int LruMax = 400;

    public AsyncImage()
    {
        SnapsToDevicePixels = true;
        _placeholder = new Border { Background = (Brush)Application.Current.FindResource("Brush.SurfaceHigh") };
        _fallback = new TextBlock
        {
            FontFamily = (FontFamily)Application.Current.FindResource("Font.Serif"),
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)Application.Current.FindResource("Brush.TextMuted"),
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxHeight = 22 * 4,
            Margin = new Thickness(12),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
        _root.Children.Add(_placeholder);
        _root.Children.Add(_fallback);
        _root.Children.Add(_image);
        Child = _root;
        SizeChanged += (_, _) => UpdateClip();
        Loaded += (_, _) => { if (_image.Source == null) Reload(); };
        Unloaded += (_, _) => { _cts?.Cancel(); StopPulse(); };
    }

    protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.Property == CornerRadiusProperty || e.Property == BorderThicknessProperty) UpdateClip();
    }

    private void UpdateClip()
    {
        var r = Math.Max(0, CornerRadius.TopLeft - BorderThickness.Left / 2);
        var w = Math.Max(0, ActualWidth - BorderThickness.Left - BorderThickness.Right);
        var h = Math.Max(0, ActualHeight - BorderThickness.Top - BorderThickness.Bottom);
        _root.Clip = r <= 0 ? null : new RectangleGeometry(new Rect(0, 0, w, h), r, r);
    }

    private void StartPulse()
    {
        if (_pulsing) return;
        _pulsing = true;
        _placeholder.BeginAnimation(OpacityProperty, new DoubleAnimation(1.0, 0.55, TimeSpan.FromMilliseconds(900))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut },
        });
    }

    private void StopPulse()
    {
        _pulsing = false;
        _placeholder.BeginAnimation(OpacityProperty, null);
        _placeholder.Opacity = 1;
    }

    private async void Reload()
    {
        _cts?.Cancel();
        var url = Url;
        if (string.IsNullOrEmpty(url))
        {
            _image.Source = null;
            StopPulse();
            _fallback.Visibility = string.IsNullOrEmpty(FallbackText) ? Visibility.Collapsed : Visibility.Visible;
            return;
        }
        _fallback.Visibility = Visibility.Collapsed;
        var key = url + "|" + DecodeWidth;
        if (LruIndex.TryGetValue(key, out var node))
        {
            Lru.Remove(node);
            Lru.AddFirst(node);
            _image.Source = node.Value.Bitmap;
            _image.Opacity = 1;
            StopPulse();
            return;
        }
        _image.Source = null;
        if (!IsLoaded) return;
        StartPulse();
        var cts = _cts = new CancellationTokenSource();
        var decode = DecodeWidth;
        try
        {
            string? path;
            var images = AppServices.Images;
            if (images != null) path = await images.GetFile(url, cts.Token);
            else path = url;
            if (cts.IsCancellationRequested) return;
            if (path == null) { ShowFailed(); return; }
            var bmp = await Task.Run(() => Decode(path, decode), cts.Token);
            if (cts.IsCancellationRequested || Url != url) return;
            if (bmp == null) { ShowFailed(); return; }
            Remember(key, bmp);
            _image.Source = bmp;
            StopPulse();
            _image.Opacity = 0;
            _image.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!cts.IsCancellationRequested) ShowFailed(); }
    }

    private void ShowFailed()
    {
        StopPulse();
        _fallback.Visibility = string.IsNullOrEmpty(FallbackText) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static BitmapSource? Decode(string path, int decodeWidth)
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bi.UriSource = new Uri(path, UriKind.Absolute);
            if (decodeWidth > 0) bi.DecodePixelWidth = decodeWidth;
            bi.EndInit();
            bi.Freeze();
            return bi;
        }
        catch (Exception) { return null; }
    }

    private static void Remember(string key, BitmapSource bmp)
    {
        if (LruIndex.ContainsKey(key)) return;
        var node = Lru.AddFirst((key, bmp));
        LruIndex[key] = node;
        while (Lru.Count > LruMax)
        {
            var last = Lru.Last!;
            LruIndex.Remove(last.Value.Key);
            Lru.RemoveLast();
        }
    }
}
