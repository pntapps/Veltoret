using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Veltoret.App.Services;

namespace Veltoret.App.Controls;

/// <summary>
/// Base for pages that show library data (Android: screens collecting Room Flows). While the page is on screen it
/// re-runs <see cref="Refresh"/> (throttled) when <c>AppServices.Db.Changed</c> names one of
/// <see cref="Tables"/>, when connectivity changes, and (if <see cref="WatchScan"/>) when the scan state changes.
/// </summary>
public abstract class LivePage : UserControl
{
    private readonly DispatcherTimer _throttle;
    private bool _dirty = true;
    private bool _running;
    private bool _again;
    private bool _subscribed;

    protected LivePage()
    {
        SetResourceReference(BackgroundProperty, "Brush.Background");
        Focusable = true;
        FocusVisualStyle = null;
        _throttle = new DispatcherTimer(DispatcherPriority.Background, Dispatcher) { Interval = TimeSpan.FromMilliseconds(250) };
        _throttle.Tick += (_, _) => { _throttle.Stop(); _ = RunRefresh(); };
        Loaded += (_, _) => { Subscribe(); if (_dirty) _ = RunRefresh(); };
        Unloaded += (_, _) => Unsubscribe();
    }

    /// <summary>Database tables whose changes make this page re-query.</summary>
    protected abstract IReadOnlyCollection<string> Tables { get; }

    protected virtual bool WatchScan => false;

    /// <summary>Re-queries and updates the UI. Runs on the UI thread; never concurrently.</summary>
    protected abstract Task Refresh();

    /// <summary>Called on the UI thread with the latest scan state when <see cref="WatchScan"/> is on.</summary>
    protected virtual void OnScanState(Veltoret.Core.Library.ScanState state) { }

    protected void Invalidate()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(Invalidate); return; }
        _dirty = true;
        if (!IsLoaded) return;
        if (!_throttle.IsEnabled) _throttle.Start();
    }

    private async Task RunRefresh()
    {
        if (_running) { _again = true; return; }
        _running = true;
        _dirty = false;
        try { await Refresh(); }
        catch (Exception ex) { App.Log(ex); }
        finally
        {
            _running = false;
            if (_again) { _again = false; Invalidate(); }
        }
    }

    private void Subscribe()
    {
        if (_subscribed) return;
        _subscribed = true;
        try { AppServices.Db.Changed += OnDbChanged; } catch (Exception) { }
        try { AppServices.Connectivity.OnlineChanged += OnOnline; } catch (Exception) { }
        if (WatchScan)
        {
            try
            {
                AppServices.Scanner.StateChanged += OnScan;
                OnScanState(AppServices.Scanner.State);
            }
            catch (Exception) { }
        }
    }

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        _subscribed = false;
        try { AppServices.Db.Changed -= OnDbChanged; } catch (Exception) { }
        try { AppServices.Connectivity.OnlineChanged -= OnOnline; } catch (Exception) { }
        try { AppServices.Scanner.StateChanged -= OnScan; } catch (Exception) { }
    }

    private void OnDbChanged(IReadOnlySet<string> tables)
    {
        foreach (var t in Tables)
        {
            if (tables.Contains(t)) { Invalidate(); return; }
        }
    }

    private void OnOnline(bool online) => Invalidate();

    private void OnScan(Veltoret.Core.Library.ScanState s) =>
        Dispatcher.BeginInvoke(() => { if (IsLoaded) OnScanState(s); });

    protected Window? OwnerWindow => Window.GetWindow(this) ?? Application.Current.MainWindow;

    protected static bool IsOnline
    {
        get
        {
            try { return AppServices.Connectivity.IsOnline; }
            catch (Exception) { return true; }
        }
    }
}
