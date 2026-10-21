using System.Collections;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;

namespace Veltoret.App.Controls;

/// <summary>
/// A virtualized adaptive grid (Compose LazyVerticalGrid(Adaptive(min))): items are chunked into rows that fit
/// <see cref="MinCellWidth"/>, and rows are virtualized vertically with pixel scrolling. Items implementing
/// <see cref="IFullSpan"/> (or any UIElement) take a whole row. Cells are laid out with <see cref="HGap"/> /
/// <see cref="VGap"/> and <see cref="Gutter"/> side padding; <see cref="Columns"/> &gt; 0 forces a column count.
/// </summary>
public sealed class VirtualGrid : ItemsControl
{
    public sealed class CellRow
    {
        public required IReadOnlyList<object> Cells { get; init; }
        public int Columns { get; init; }
    }

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(nameof(Source), typeof(IEnumerable), typeof(VirtualGrid),
        new PropertyMetadata(null, (d, _) => ((VirtualGrid)d).Rebuild()));

    public IEnumerable? Source { get => (IEnumerable?)GetValue(SourceProperty); set => SetValue(SourceProperty, value); }

    public DataTemplate? CellTemplate { get; set; }
    public double MinCellWidth { get; set; } = 156;
    public int Columns { get; set; }
    public double HGap { get; set; } = 20;
    public double VGap { get; set; } = 28;
    public double Gutter { get; set; } = UiKit.Gutter;
    public double TopPadding { get; set; }
    public double BottomPadding { get; set; } = 32;
    /// <summary>Column count currently used.</summary>
    public int CurrentColumns { get; private set; } = 1;

    private double _lastWidth = -1;
    private ScrollViewer? _scroll;

    public VirtualGrid()
    {
        Focusable = false;
        VirtualizingPanel.SetIsVirtualizing(this, true);
        VirtualizingPanel.SetVirtualizationMode(this, VirtualizationMode.Recycling);
        VirtualizingPanel.SetScrollUnit(this, ScrollUnit.Pixel);
        VirtualizingPanel.SetCacheLength(this, new VirtualizationCacheLength(1, 2));
        VirtualizingPanel.SetCacheLengthUnit(this, VirtualizationCacheLengthUnit.Page);
        ScrollViewer.SetCanContentScroll(this, true);
        ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(VirtualizingStackPanel)));
        var sv = new FrameworkElementFactory(typeof(ScrollViewer));
        sv.SetValue(ScrollViewer.CanContentScrollProperty, true);
        sv.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Disabled);
        sv.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto);
        sv.SetValue(FocusableProperty, false);
        sv.SetValue(SmoothScroll.IsEnabledProperty, true);
        sv.AppendChild(new FrameworkElementFactory(typeof(ItemsPresenter)));
        Template = new ControlTemplate(typeof(VirtualGrid)) { VisualTree = sv };
        ItemTemplateSelector = new RowSelector(this);
        SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - _lastWidth) > 0.5) { _lastWidth = e.NewSize.Width; Rebuild(onlyIfColumnsChanged: true); } };
    }

    public ScrollViewer? ScrollViewer => _scroll;

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        _scroll = System.Windows.Media.VisualTreeHelper.GetChildrenCount(this) > 0 ? System.Windows.Media.VisualTreeHelper.GetChild(this, 0) as ScrollViewer : null;
    }

    public void ScrollToTop() => ScrollViewer?.ScrollToVerticalOffset(0);

    private int ComputeColumns()
    {
        if (Columns > 0) return Columns;
        var w = ActualWidth - 2 * Gutter - 10; // leave room for the scroll bar overlay
        if (w <= 0) return CurrentColumns;
        return Math.Max(1, (int)Math.Floor((w + HGap) / (MinCellWidth + HGap)));
    }

    private void Rebuild(bool onlyIfColumnsChanged = false)
    {
        var cols = ComputeColumns();
        if (onlyIfColumnsChanged && cols == CurrentColumns && ItemsSource != null) return;
        CurrentColumns = cols;
        var rows = new List<object>();
        var pending = new List<object>();
        void Flush()
        {
            if (pending.Count == 0) return;
            rows.Add(new CellRow { Cells = pending.ToList(), Columns = cols });
            pending.Clear();
        }
        if (Source != null)
        {
            foreach (var item in Source)
            {
                if (item is IFullSpan || item is UIElement)
                {
                    Flush();
                    rows.Add(item is UIElement ue ? new GridHeader(ue) : item);
                    continue;
                }
                pending.Add(item);
                if (pending.Count == cols) Flush();
            }
        }
        Flush();
        if (TopPadding > 0) rows.Insert(0, new Spacer(TopPadding));
        if (BottomPadding > 0) rows.Add(new Spacer(BottomPadding));
        ItemsSource = rows;
    }

    private sealed record Spacer(double Height) : IFullSpan;

    private sealed class RowSelector(VirtualGrid grid) : DataTemplateSelector
    {
        private DataTemplate? _row;
        private DataTemplate? _full;
        private DataTemplate? _spacer;

        public override DataTemplate SelectTemplate(object item, DependencyObject container)
        {
            if (item is Spacer) return _spacer ??= BuildSpacer();
            if (item is CellRow) return _row ??= BuildRow();
            return _full ??= BuildFull();
        }

        private DataTemplate BuildSpacer()
        {
            var f = new FrameworkElementFactory(typeof(Border));
            f.SetBinding(HeightProperty, new Binding(nameof(Spacer.Height)));
            return new DataTemplate { VisualTree = f };
        }

        private DataTemplate BuildFull()
        {
            var f = new FrameworkElementFactory(typeof(ContentPresenter));
            f.SetBinding(ContentPresenter.ContentProperty, new Binding(item => item is GridHeader h ? h.Content : item));
            f.SetValue(MarginProperty, new Thickness(grid.Gutter, 0, grid.Gutter, 0));
            return new DataTemplate { VisualTree = f };
        }

        private DataTemplate BuildRow()
        {
            var ic = new FrameworkElementFactory(typeof(ItemsControl));
            ic.SetBinding(ItemsSourceProperty, new Binding(nameof(CellRow.Cells)));
            ic.SetValue(FocusableProperty, false);
            ic.SetValue(MarginProperty, new Thickness(grid.Gutter - grid.HGap / 2, 0, grid.Gutter - grid.HGap / 2, grid.VGap));
            var panel = new FrameworkElementFactory(typeof(UniformGrid));
            panel.SetBinding(UniformGrid.ColumnsProperty, new Binding(nameof(CellRow.Columns)));
            panel.SetValue(UniformGrid.RowsProperty, 1);
            ic.SetValue(ItemsPanelProperty, new ItemsPanelTemplate(panel));
            var cell = new Style(typeof(ContentPresenter));
            cell.Setters.Add(new Setter(MarginProperty, new Thickness(grid.HGap / 2, 0, grid.HGap / 2, 0)));
            cell.Setters.Add(new Setter(VerticalAlignmentProperty, VerticalAlignment.Top));
            ic.SetValue(ItemContainerStyleProperty, cell);
            ic.SetValue(ItemTemplateSelectorProperty, new CellSelector(grid));
            return new DataTemplate { VisualTree = ic };
        }
    }

    private sealed class CellSelector(VirtualGrid grid) : DataTemplateSelector
    {
        private static DataTemplate? _host;

        public override DataTemplate? SelectTemplate(object item, DependencyObject container)
        {
            if (item is UiCell) return _host ??= new DataTemplate { VisualTree = new FrameworkElementFactory(typeof(UiCellHost)) };
            return grid.CellTemplate;
        }
    }

    /// <summary>Binding whose value is computed from the item itself.</summary>
    private sealed class Binding : System.Windows.Data.Binding
    {
        public Binding(string path) : base(path) { }
        public Binding(Func<object?, object?> f) : base(".") { Converter = new FnConverter(f); }

        private sealed class FnConverter(Func<object?, object?> f) : IValueConverter
        {
            public object? Convert(object? value, Type targetType, object? parameter, System.Globalization.CultureInfo culture) => f(value);
            public object? ConvertBack(object? value, Type targetType, object? parameter, System.Globalization.CultureInfo culture) => DependencyProperty.UnsetValue;
        }
    }
}
