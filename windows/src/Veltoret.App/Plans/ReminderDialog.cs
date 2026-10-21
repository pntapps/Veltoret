using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Plans;
using P = Veltoret.Core.Plans.Plans;

namespace Veltoret.App.Plans;

/// <summary>
/// "Remind me" (Android: TitlePlans.ReminderDialog): one-tap times (tonight, tomorrow, Saturday, and "When it
/// airs" for an episode that hasn't aired) or any date and time. Also lists the title's pending reminders so
/// they can be cancelled.
/// </summary>
public sealed class ReminderDialog
{
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    /// <summary>
    /// Shows the dialog; true when a reminder was set. <paramref name="title"/> is stored with the reminder
    /// (movie title, show name, or "Show · S1 · E2"). <paramref name="airDate"/> ("yyyy-MM-dd") adds
    /// "When it airs (…, 8 PM)" while the episode is upcoming.
    /// </summary>
    public static async Task<bool> Show(Window owner, string type, int id, int? season, int? episode, string title, string? airDate)
    {
        var extra = new List<(string Label, DateTime At)>();
        if (P.IsUpcoming(airDate, DateOnly.FromDateTime(DateTime.Now)) && P.Parse(airDate) is { } d)
            extra.Add(($"When it airs ({P.AirLabel(airDate, DateOnly.FromDateTime(DateTime.Now))}, 8 PM)", d.ToDateTime(new TimeOnly(20, 0))));

        List<ReminderEntity> existing;
        try { existing = await AppServices.Plans.RemindersFor(type, id); }
        catch (Exception) { existing = new(); }

        var flow = new Flow(owner, title, extra, existing);
        flow.ShowChoices();
        flow.Window.ShowDialog();
        if (flow.Picked is not { } at) return false;

        var ms = P.ToMillis(at);
        var label = P.ReminderLabel(ms, DateTime.Now);
        await AppServices.Plans.AddReminder(type, id, season, episode, title, DateTimeOffset.FromUnixTimeMilliseconds(ms));
        if (ToastNotifier.CanPostNow())
            Controls.Toast.Show($"Reminder set for {label}");
        else
            Controls.Toast.Show($"Reminder set for {label}. Allow notifications so it can appear.", "Settings",
                () => Ui.OpenUrl("ms-settings:notifications"));
        return true;
    }

    private sealed class Flow
    {
        private readonly string _title;
        private readonly List<(string Label, DateTime At)> _extra;
        private readonly List<ReminderEntity> _existing;
        private DateOnly _date = DateOnly.FromDateTime(DateTime.Now);
        private DateOnly _month;

        public PlansDialog Window { get; }
        public DateTime? Picked { get; private set; }

        public Flow(Window owner, string title, List<(string, DateTime)> extra, List<ReminderEntity> existing)
        {
            _title = title;
            _extra = extra;
            _existing = existing;
            _month = new DateOnly(_date.Year, _date.Month, 1);
            Window = new PlansDialog(owner) { Title = "Remind me" };
        }

        private void Pick(DateTime at)
        {
            Picked = at;
            Window.Close();
        }

        // Step 0: choices.
        public void ShowChoices()
        {
            Window.Heading = "Remind me";
            var body = new StackPanel();
            body.Children.Add(Ui.Text(_title, "Text.BodyMedium", "Brush.TextMuted"));
            body.Children.Add(new Border { Height = 12 });

            var now = DateTime.Now;
            foreach (var (label, at) in _extra.Where(e => e.At > now).Concat(P.QuickTimes(now)))
                body.Children.Add(ChoiceRow("Notifications", label, () => Pick(at)));
            body.Children.Add(ChoiceRow("Edit", "Pick a date and time…", ShowDate));

            if (_existing.Count > 0)
            {
                body.Children.Add(new Border { Height = 10 });
                body.Children.Add(Ui.Divider());
                var list = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
                Fill(list);
                body.Children.Add(list);
            }

            Window.Body = body;
            Window.ClearButtons();
            Window.AddButton("Cancel", Window.Close);
        }

        private void Fill(StackPanel list)
        {
            list.Children.Clear();
            var now = DateTime.Now;
            foreach (var r in _existing.OrderBy(r => r.At))
            {
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var close = Ui.IconButton("Close", "Cancel reminder", async () =>
                {
                    _existing.Remove(r);
                    try { await AppServices.Plans.RemoveReminder(r.Id); } catch (Exception) { }
                    Fill(list);
                }, 30);
                DockPanel.SetDock(close, Dock.Right);
                row.Children.Add(close);
                var icon = Ui.Icon("Notifications", 18);
                icon.Margin = new Thickness(0, 0, 8, 0);
                DockPanel.SetDock(icon, Dock.Left);
                row.Children.Add(icon);
                var parts = new List<string>();
                if (r.Season != null && r.Episode != null) parts.Add(PlanFormat.EpisodeCode(r.Season, r.Episode));
                parts.Add($"Reminder {P.ReminderLabel(r.At, now)}");
                var text = Ui.OneLine(string.Join("  ·  ", parts), "Text.BodyMedium");
                text.VerticalAlignment = VerticalAlignment.Center;
                row.Children.Add(text);
                list.Children.Add(row);
            }
        }

        private static Button ChoiceRow(string icon, string label, Action onClick)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 12, 8, 12) };
            var i = Ui.Icon(icon, 20);
            i.Margin = new Thickness(0, 0, 14, 0);
            content.Children.Add(i);
            var t = Ui.Text(label, "Text.BodyLarge");
            t.VerticalAlignment = VerticalAlignment.Center;
            content.Children.Add(t);
            var b = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch };
            Ui.Apply(b, "Button.Row");
            b.Click += (_, _) => onClick();
            return b;
        }

        // Step 1: date (today or later).
        private void ShowDate()
        {
            Window.Heading = "";
            Window.Body = MonthView();
            Window.ClearButtons();
            Window.AddButton("Cancel", Window.Close);
            Window.AddButton("Next", ShowTime, accent: true);
        }

        private FrameworkElement MonthView()
        {
            var today = DateOnly.FromDateTime(DateTime.Now);
            var root = new StackPanel();
            root.Children.Add(Ui.Text("Select date", "Text.LabelMedium", "Brush.TextMuted"));
            var big = Ui.Text(_date.ToString("ddd, MMM d", Us), "Text.HeadlineMedium");
            big.Margin = new Thickness(0, 6, 0, 14);
            root.Children.Add(big);

            var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var prev = Ui.IconButton("ChevronLeft", "Previous month", () => { _month = _month.AddMonths(-1); Window.Body = MonthView(); }, 34, "Brush.Text");
            var next = Ui.IconButton("ChevronRight", "Next month", () => { _month = _month.AddMonths(1); Window.Body = MonthView(); }, 34, "Brush.Text");
            prev.IsEnabled = _month > new DateOnly(today.Year, today.Month, 1);
            DockPanel.SetDock(next, Dock.Right);
            DockPanel.SetDock(prev, Dock.Right);
            header.Children.Add(next);
            header.Children.Add(prev);
            var monthName = Ui.Text(_month.ToString("MMMM yyyy", Us), "Text.TitleSmall");
            monthName.VerticalAlignment = VerticalAlignment.Center;
            header.Children.Add(monthName);
            root.Children.Add(header);

            var grid = new UniformGrid { Columns = 7 };
            foreach (var dn in new[] { "S", "M", "T", "W", "T", "F", "S" })
            {
                var t = Ui.Text(dn, "Text.LabelMedium", "Brush.TextMuted");
                t.HorizontalAlignment = HorizontalAlignment.Center;
                t.Margin = new Thickness(0, 0, 0, 6);
                grid.Children.Add(t);
            }
            for (var i = 0; i < (int)_month.DayOfWeek; i++) grid.Children.Add(new Border());
            var days = DateTime.DaysInMonth(_month.Year, _month.Month);
            for (var day = 1; day <= days; day++)
            {
                var date = new DateOnly(_month.Year, _month.Month, day);
                var selected = date == _date;
                var cell = new Button
                {
                    Content = day.ToString(Us),
                    Width = 40,
                    Height = 40,
                    Margin = new Thickness(1),
                    IsEnabled = date >= today,
                };
                Ui.Apply(cell, "Button.IconFlat");
                cell.Foreground = selected ? Ui.Brush("Brush.OnAmber") : date == today ? Ui.Brush("Brush.Amber") : Ui.Brush("Brush.Text");
                if (selected) cell.Background = Ui.Brush("Brush.Amber");
                else if (date == today) { cell.BorderBrush = Ui.Brush("Brush.Amber"); cell.BorderThickness = new Thickness(1); }
                if (date < today) cell.Opacity = 0.38;
                cell.Click += (_, _) => { _date = date; Window.Body = MonthView(); };
                grid.Children.Add(cell);
            }
            root.Children.Add(grid);
            return root;
        }

        // Step 2: time (12-hour, 8:00 PM to start).
        private void ShowTime()
        {
            Window.Heading = PlanFormat.Date(_date);
            var hours = Combo(Enumerable.Range(1, 12).Select(h => h.ToString(Us)), 7);
            var minutes = Combo(Enumerable.Range(0, 60).Select(m => m.ToString("00", Us)), 0);
            var ampm = Combo(new[] { "AM", "PM" }, 1);
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(hours);
            var colon = Ui.Text(":", "Text.HeadlineSmall");
            colon.Margin = new Thickness(8, 0, 8, 0);
            colon.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(colon);
            row.Children.Add(minutes);
            ampm.Margin = new Thickness(12, 0, 0, 0);
            row.Children.Add(ampm);
            Window.Body = row;

            Window.ClearButtons();
            Window.AddButton("Back", ShowDate);
            DateTime Chosen()
            {
                var h = hours.SelectedIndex + 1;
                var h24 = (h % 12) + (ampm.SelectedIndex == 1 ? 12 : 0);
                return _date.ToDateTime(new TimeOnly(h24, minutes.SelectedIndex));
            }
            var set = Window.AddButton("Set reminder", () => { if (Chosen() > DateTime.Now) Pick(Chosen()); }, accent: true);
            void Update() => set.IsEnabled = Chosen() > DateTime.Now;
            hours.SelectionChanged += (_, _) => Update();
            minutes.SelectionChanged += (_, _) => Update();
            ampm.SelectionChanged += (_, _) => Update();
            Update();
        }

        private static ComboBox Combo(IEnumerable<string> items, int selected)
        {
            var c = new ComboBox { MinWidth = 76, ItemsSource = items.ToList(), SelectedIndex = selected, VerticalAlignment = VerticalAlignment.Center };
            Ui.Apply(c, "ComboBox");
            return c;
        }
    }
}
