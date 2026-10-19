using System.Windows;
using System.Windows.Controls;
using Veltoret.App.Controls;
using Veltoret.Core.Cast;

namespace Veltoret.App.Network;

/// <summary>
/// "Audio on the TV": asked before casting a video with several audio tracks, since a Chromecast plays only the one
/// it's given. The current track is marked; "Keep current" (or Esc) keeps it.
/// </summary>
public static class CastAudioDialog
{
    /// <summary>The chosen MKV track number, or null to keep the current one.</summary>
    public static long? Ask(Window? owner, string? deviceName, IReadOnlyList<CastAudioOption> options, long? current)
    {
        var dialog = new DialogWindow { DialogTitle = $"Audio on {deviceName ?? "the TV"}" };
        long? chosen = null;
        var list = new StackPanel { MinWidth = 340 };
        foreach (var option in options)
        {
            var selected = option.Track == current;
            var text = new StackPanel();
            text.Children.Add(UiKit.Text(option.Label, "Text.TitleMedium", selected ? "Amber" : "Text", maxLines: 1));
            if (!string.IsNullOrWhiteSpace(option.Detail)) text.Children.Add(UiKit.Text(option.Detail, "Text.BodySmall", "TextMuted", maxLines: 1));
            var row = new DockPanel { LastChildFill = true };
            if (selected)
            {
                var mark = UiKit.Text("Current", "Text.LabelMedium", "Amber", wrap: false);
                mark.VerticalAlignment = VerticalAlignment.Center;
                mark.Margin = new Thickness(12, 0, 0, 0);
                DockPanel.SetDock(mark, Dock.Right);
                row.Children.Add(mark);
            }
            row.Children.Add(text);
            var button = new Button
            {
                Style = UiKit.Style("Button.Row"), Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(6, 12, 6, 12),
            };
            var track = option.Track;
            button.Click += (_, _) => { chosen = track; dialog.Finish(new DialogButton("ok")); };
            list.Children.Add(button);
        }
        var hint = UiKit.Text("You can switch later from the casting panel.", "Text.BodySmall", "TextMuted");
        hint.Margin = new Thickness(6, 8, 0, 0);
        list.Children.Add(hint);
        dialog.Body = list;
        dialog.SetButtons(DialogButton.Cancel("Keep current"));
        dialog.ShowModal(owner);
        return chosen;
    }
}
