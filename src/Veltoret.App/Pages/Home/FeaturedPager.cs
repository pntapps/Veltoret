using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;

namespace Veltoret.App.Pages.Home;

/// <summary>
/// Featured hero (Expanded layout): backdrop (weight 1.2, 16:9, corner 20) | 36 | info (eyebrow, title, rating +
/// meta, overview, Play / Details). Auto-advances every 8 s when there is more than one item; bar indicator below.
/// </summary>
public sealed class FeaturedPager : StackPanel
{
    private readonly Grid _host = new() { ClipToBounds = false };
    private readonly StackPanel _dots = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(UiKit.Gutter, 16, 0, 0) };
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(8) };
    private IReadOnlyList<FeaturedItem> _items = Array.Empty<FeaturedItem>();
    private int _index;
    private FrameworkElement? _current;

    public FeaturedPager()
    {
        Margin = new Thickness(0, 0, 0, 8);
        _host.Margin = new Thickness(UiKit.Gutter, 0, UiKit.Gutter, 0);
        Children.Add(_host);
        Children.Add(_dots);
        _timer.Tick += (_, _) => { if (_items.Count > 1 && !IsMouseOver) Show((_index + 1) % _items.Count, forward: true); };
        Loaded += (_, _) => Restart();
        Unloaded += (_, _) => _timer.Stop();
    }

    public void SetItems(IReadOnlyList<FeaturedItem> items)
    {
        if (items.SequenceEqual(_items)) return;
        var currentId = _index < _items.Count ? (_items[_index].Id, _items[_index].IsShow) : default;
        _items = items;
        var keep = items.ToList().FindIndex(i => (i.Id, i.IsShow) == currentId);
        _index = keep >= 0 ? keep : 0;
        _host.Children.Clear();
        _current = null;
        if (items.Count > 0) Show(_index, forward: true, animate: false);
        RenderDots();
        Restart();
    }

    private void Restart()
    {
        _timer.Stop();
        if (_items.Count > 1 && IsLoaded) _timer.Start();
    }

    private void Show(int index, bool forward, bool animate = true)
    {
        if (_items.Count == 0) return;
        _index = index;
        var page = BuildPage(_items[index]);
        var old = _current;
        _current = page;
        _host.Children.Add(page);
        if (animate && old != null)
        {
            var dx = forward ? 80 : -80;
            var t = new TranslateTransform(dx, 0);
            page.RenderTransform = t;
            page.Opacity = 0;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            page.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(420)) { EasingFunction = ease });
            t.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(480)) { EasingFunction = ease });
            var ot = new TranslateTransform();
            old.RenderTransform = ot;
            old.IsHitTestVisible = false;
            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(260));
            fade.Completed += (_, _) => _host.Children.Remove(old);
            old.BeginAnimation(OpacityProperty, fade);
            ot.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-dx, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        }
        else if (old != null) _host.Children.Remove(old);
        RenderDots();
    }

    private void RenderDots()
    {
        _dots.Children.Clear();
        _dots.Visibility = _items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        for (var i = 0; i < _items.Count; i++)
        {
            var index = i;
            var bar = new Border
            {
                Height = 3,
                Width = i == _index ? 22 : 8,
                CornerRadius = new CornerRadius(2),
                Background = UiKit.Brush(i == _index ? "Amber" : "OutlineStrong"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var hit = new Button { Style = UiKit.Style("Button.Plain"), Content = bar, Padding = new Thickness(0, 6, 0, 6), Margin = new Thickness(i == 0 ? 0 : 6, 0, 0, 0), ToolTip = _items[i].Title, Focusable = false };
            hit.Click += (_, _) => { if (index != _index) { Show(index, index > _index); Restart(); } };
            _dots.Children.Add(hit);
        }
    }

    private static void Open(FeaturedItem item)
    {
        Route r = item.IsShow ? new ShowDetailRoute(item.Id) : new MovieDetailRoute(item.Id);
        AppServices.Navigator.Navigate(r);
    }

    private static async void Play(FeaturedItem item)
    {
        try
        {
            if (item.IsShow) await AppServices.Playback.PlayShow(item.Id);
            else await AppServices.Playback.PlayMovie(item.Id);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    private static FrameworkElement BuildPage(FeaturedItem item)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.2, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var image = new AsyncImage
        {
            Url = item.BackdropUrl, FallbackText = item.Title, DecodeWidth = 1280,
            CornerRadius = new CornerRadius(20), BorderThickness = new Thickness(1), BorderBrush = UiKit.Brush("Outline"),
        };
        var imageButton = new Button
        {
            Style = UiKit.Style("Button.Plain"),
            Content = new AspectBox { Ratio = 9.0 / 16.0, Child = image },
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = item.Title,
        };
        Motion.SetPressScale(imageButton, 0.98);
        imageButton.Click += (_, _) => Open(item);
        grid.Children.Add(imageButton);

        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(info, 2);
        info.Children.Add(UiKit.Text(item.IsShow ? "SERIES" : "FILM", "Text.LabelSmall", "Amber", maxLines: 1));
        var title = UiKit.Text(item.Title, "Text.DisplaySmall", maxLines: 3);
        title.Margin = new Thickness(0, 6, 0, 0);
        info.Children.Add(title);
        var metaRow = new DockPanel { Margin = new Thickness(0, 8, 0, 0), LastChildFill = true };
        if (UiKit.Rating(item.Rating) is { } rating)
        {
            rating.Margin = new Thickness(0, 0, 12, 0);
            DockPanel.SetDock(rating, Dock.Left);
            metaRow.Children.Add(rating);
        }
        metaRow.Children.Add(UiKit.MetaLine(item.Meta));
        info.Children.Add(metaRow);
        if (!string.IsNullOrWhiteSpace(item.Overview))
        {
            var overview = UiKit.Text(item.Overview, "Text.BodyMedium", "TextMuted", maxLines: 3);
            overview.Margin = new Thickness(0, 10, 0, 0);
            info.Children.Add(overview);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 16, 0, 0) };
        buttons.Children.Add(UiKit.Button("Play", "Button.Primary", "Play", () => Play(item)));
        var details = UiKit.Button("Details", "Button.Secondary", "Info", () => Open(item));
        details.Margin = new Thickness(10, 0, 0, 0);
        buttons.Children.Add(details);
        info.Children.Add(buttons);
        grid.Children.Add(info);
        return grid;
    }
}
