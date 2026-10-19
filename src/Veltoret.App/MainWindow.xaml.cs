using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Veltoret.App.Controls;
using Veltoret.App.Navigation;
using Veltoret.App.Services;
using Veltoret.App.Shell;

namespace Veltoret.App;

/// <summary>
/// The shell (Android AppShell, Expanded layout): nav rail on the left, the page host bound to
/// <see cref="AppServices.Navigator"/>, Back (Alt+Left, Backspace / Esc outside text boxes, mouse back button),
/// Ctrl+F for Search, toasts, dark title bar.
/// </summary>
public partial class MainWindow : Window
{
    private sealed record RailEntry(string Label, string Icon, Func<Route> Route, Func<Route, bool> Matches, Button Button, Border Pill, Controls.Icon Glyph, TextBlock Text);

    private readonly List<RailEntry> _rail = new();
    private FrameworkElement? _shown;

    public MainWindow()
    {
        InitializeComponent();
        try { Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Veltoret.ico")); }
        catch (Exception) { /* the exe's icon is used */ }
        DarkTitleBar.Attach(this);
        Toast.Attach(ToastHost);
        BuildRail();

        var nav = AppServices.Navigator;
        nav.Navigated += OnNavigated;
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewMouseDown += OnPreviewMouseDown;
        Closing += OnClosing;

        try
        {
            AppServices.Connectivity.OnlineChanged += online => Dispatcher.BeginInvoke(() => SetOffline(!online));
            SetOffline(!AppServices.Connectivity.IsOnline, animate: false);
        }
        catch (Exception) { }

        Loaded += (_, _) => ShowStart();
    }

    private void ShowStart()
    {
        if (AppServices.Navigator.Current != null) return;
        try
        {
            if (!AppServices.Settings.Current.OnboardingComplete && AppServices.Navigator.IsRegistered(typeof(OnboardingRoute)))
                AppServices.Navigator.Navigate(new OnboardingRoute());
            else
                AppServices.Navigator.Navigate(new HomeRoute());
        }
        catch (Exception ex) { App.Log(ex); }
    }

    // ---------------- Rail ----------------

    private void BuildRail()
    {
        Add("Home", "Home", () => new HomeRoute(), r => r is HomeRoute);
        Add("Movies", "Movie", () => new MoviesRoute(), r => r is MoviesRoute);
        Add("TV Shows", "LiveTv", () => new ShowsRoute(), r => r is ShowsRoute);
        Add("Search", "Search", () => new SearchRoute(), r => r is SearchRoute);
        Add("Files", "Folder", () => new FilesRoute(), r => r is FilesRoute);
        Add("Settings", "Settings", () => new SettingsRoute(), r => r is SettingsRoute);
    }

    private void Add(string label, string icon, Func<Route> route, Func<Route, bool> matches)
    {
        var glyph = new Controls.Icon { Data = Controls.Icon.Get(icon), Size = 24, Fill = (Brush)FindResource("Brush.TextMuted") };
        var pill = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(18, 8, 18, 8), Background = (Brush)FindResource("Brush.Surface"), Child = glyph, HorizontalAlignment = HorizontalAlignment.Center };
        pill.SetResourceReference(Border.BackgroundProperty, "Brush.Surface");
        var text = new TextBlock { Text = label, Style = (Style)FindResource("Text.LabelSmall"), Foreground = (Brush)FindResource("Brush.TextMuted"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        var stack = new StackPanel();
        stack.Children.Add(pill);
        stack.Children.Add(text);
        var button = new Button
        {
            Style = (Style)FindResource("Button.Row"),
            Padding = new Thickness(6),
            Margin = new Thickness(0, 6, 0, 6),
            Content = stack,
            ToolTip = label,
        };
        AutomationPropertiesHelper.SetName(button, label);
        var entry = new RailEntry(label, icon, route, matches, button, pill, glyph, text);
        button.Click += (_, _) => SelectTab(entry);
        _rail.Add(entry);
        RailItems.Children.Add(button);
    }

    private void SelectTab(RailEntry entry)
    {
        var nav = AppServices.Navigator;
        var route = entry.Route();
        try
        {
            if (!nav.IsRegistered(route.GetType())) { Toast.Show($"{entry.Label} isn't available yet"); return; }
            if (route is SearchRoute) nav.Push(route);
            else if (nav.Current?.Route is { } cur && entry.Matches(cur)) return;
            else nav.SelectTab(route);
        }
        catch (Exception ex) { App.Log(ex); Toast.Show(ex.Message); }
    }

    private void UpdateRail()
    {
        var nav = AppServices.Navigator;
        var top = nav.Current?.Route is SearchRoute ? nav.Current.Value.Route : nav.CurrentTopLevel;
        foreach (var e in _rail)
        {
            var selected = e.Matches(top);
            if (selected) e.Pill.SetResourceReference(Border.BackgroundProperty, "Brush.AmberDim");
            else e.Pill.SetResourceReference(Border.BackgroundProperty, "Brush.Surface");
            e.Glyph.Fill = (Brush)FindResource(selected ? "Brush.Amber" : "Brush.TextMuted");
            e.Text.Foreground = (Brush)FindResource(selected ? "Brush.Amber" : "Brush.TextMuted");
        }
    }

    private void SetOffline(bool offline, bool animate = true)
    {
        if (offline) OfflineLabel.Visibility = Visibility.Visible;
        var a = new DoubleAnimation(offline ? 1 : 0, TimeSpan.FromMilliseconds(animate ? 250 : 0));
        if (!offline) a.Completed += (_, _) => { if (OfflineLabel.Opacity == 0) OfflineLabel.Visibility = Visibility.Collapsed; };
        OfflineLabel.BeginAnimation(OpacityProperty, a);
    }

    // ---------------- Page host ----------------

    private void OnNavigated()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(OnNavigated); return; }
        var nav = AppServices.Navigator;
        if (nav.Current is not { } current) return;
        Rail.Visibility = current.Route is OnboardingRoute ? Visibility.Collapsed : Visibility.Visible;
        UpdateRail();
        var page = current.Page;
        if (page == _shown) return;
        var old = _shown;
        _shown = page;
        var back = nav.LastNavigationWasBack;
        var shift = Math.Max(1, PageHost.ActualWidth) / 6;

        if (page.Parent is Panel p && p != PageHost) p.Children.Remove(page);
        if (!PageHost.Children.Contains(page)) PageHost.Children.Add(page);
        page.BeginAnimation(OpacityProperty, null);
        var t = new TranslateTransform();
        page.RenderTransform = t;
        page.IsHitTestVisible = true;

        if (old != null)
        {
            old.IsHitTestVisible = false;
            var oldT = old.RenderTransform as TranslateTransform ?? new TranslateTransform();
            old.RenderTransform = oldT;
            var outMs = back ? 260 : 180;
            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(outMs));
            fade.Completed += (_, _) =>
            {
                if (old != _shown) PageHost.Children.Remove(old);
            };
            old.BeginAnimation(OpacityProperty, fade);
            if (back) oldT.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(0, shift, TimeSpan.FromMilliseconds(260)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn } });
            // Keep the incoming page on top for push, below for pop (the leaving page slides away over it).
            if (back)
            {
                PageHost.Children.Remove(page);
                PageHost.Children.Insert(0, page);
            }
        }

        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        if (back || old == null)
        {
            page.BeginAnimation(OpacityProperty, new DoubleAnimation(old == null ? 0 : 0, 1, TimeSpan.FromMilliseconds(old == null ? 200 : 260)));
        }
        else
        {
            page.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
            t.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(shift, 0, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        }
        // Move focus into the new page so keyboard shortcuts and scrolling work at once.
        Dispatcher.BeginInvoke(() =>
        {
            if (Keyboard.FocusedElement is DependencyObject f && IsDescendant(page, f)) return;
            // Focus the page itself (no focus ring on its first button); Tab then moves into it.
            page.Focusable = true;
            page.FocusVisualStyle = null;
            page.Focus();
        }, System.Windows.Threading.DispatcherPriority.Input);
    }

    private static bool IsDescendant(DependencyObject ancestor, DependencyObject node)
    {
        for (var d = node; d != null; d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d == ancestor) return true;
        return false;
    }

    // ---------------- Keyboard / mouse ----------------

    private static bool InTextInput() =>
        Keyboard.FocusedElement is TextBoxBase or PasswordBox or ComboBox { IsEditable: true };

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var nav = AppServices.Navigator;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Left && Keyboard.Modifiers == ModifierKeys.Alt) { e.Handled = GoBack(); return; }
        if (key == Key.BrowserBack) { e.Handled = GoBack(); return; }
        if (key == Key.F && Keyboard.Modifiers == ModifierKeys.Control)
        {
            if (nav.Current?.Route is OnboardingRoute) return;
            if (nav.Current?.Route is not SearchRoute && nav.IsRegistered(typeof(SearchRoute))) nav.Push(new SearchRoute());
            e.Handled = true;
            return;
        }
        if (key == Key.Back && !InTextInput() && Keyboard.Modifiers == ModifierKeys.None) { e.Handled = GoBack(); return; }
        if (key == Key.Escape && !InTextInput() && Keyboard.Modifiers == ModifierKeys.None) { e.Handled = GoBack(); }
    }

    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.XButton1) e.Handled = GoBack();
    }

    private static bool GoBack()
    {
        var nav = AppServices.Navigator;
        if (nav.Current?.Route is OnboardingRoute) return false;
        return nav.GoBack();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        // Keep running in the notification area (reminders, alerts, scans) unless the user turned that off.
        bool background;
        try { background = AppServices.Settings.Current.RunInBackground; }
        catch (Exception) { background = false; }
        if (background && !Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        Application.Current.Shutdown();
    }
}

internal static class AutomationPropertiesHelper
{
    public static void SetName(DependencyObject o, string name) => System.Windows.Automation.AutomationProperties.SetName(o, name);
}
