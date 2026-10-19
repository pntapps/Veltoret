using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Veltoret.Core.Drive;
using static Veltoret.App.Pages.Files.FileUi;

namespace Veltoret.App.Pages.Files;

/// <summary>
/// An upload or extraction in progress (Android: TransferCard): icon, title, status ("Failed" / "Done" /
/// "Waiting" / "{percent}%"), an optional detail line and a progress bar while it runs. Failed cards have a
/// danger border; clicking a finished or failed card dismisses it.
/// </summary>
internal sealed class TransferCard : Border
{
    public TransferCard(TransferJob job, string? title = null, bool dismissible = true)
    {
        var failed = job.State == TransferState.Failed;
        var done = job.State == TransferState.Succeeded;
        var waiting = job.State is TransferState.Enqueued or TransferState.Waiting;
        var percent = (int)Math.Round(Math.Clamp(job.Progress, 0, 1) * 100);

        Style = FileUi.Style("Card");
        Padding = new Thickness(14, 12, 14, 12);
        if (failed) BorderBrush = Brush("Danger45");

        var icon = failed ? Icons.Error : done ? Geo("CheckCircle") : job.Kind == TransferKind.Upload ? Icons.CloudUpload : Icons.Unarchive;
        var iconColor = failed ? Brush("Danger") : done ? Brush("Success") : Brush("Amber");

        var head = new DockPanel();
        var status = Text(failed ? "Failed" : done ? "Done" : waiting ? "Waiting" : $"{percent}%", "Text.LabelMedium",
            failed ? Brush("Danger") : Brush("TextMuted"), wrap: false);
        status.Margin = new Thickness(10, 0, 0, 0);
        DockPanel.SetDock(status, Dock.Right);
        head.Children.Add(status);
        var iconEl = IconOf(icon, 20, iconColor);
        iconEl.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(iconEl, Dock.Left);
        head.Children.Add(iconEl);
        head.Children.Add(Text(title ?? job.Name, "Text.TitleSmall", wrap: false));

        var stack = new StackPanel();
        stack.Children.Add(head);
        var detail = Detail(job);
        if (!string.IsNullOrEmpty(detail))
        {
            var t = Text(detail, "Text.BodySmall", failed ? Brush("Danger") : Brush("TextMuted"));
            t.MaxHeight = 34;
            t.TextTrimming = TextTrimming.CharacterEllipsis;
            t.Margin = new Thickness(30, 4, 0, 0);
            stack.Children.Add(t);
        }
        if (!job.IsFinished)
        {
            var bar = new ProgressBar
            {
                Style = FileUi.Style("ProgressBar"),
                Value = job.Progress,
                IsIndeterminate = waiting || (job.State == TransferState.Running && job.Progress <= 0),
                Margin = new Thickness(0, 10, 0, 0),
            };
            stack.Children.Add(bar);
        }
        Child = stack;

        if (dismissible && job.IsFinished)
        {
            Cursor = System.Windows.Input.Cursors.Hand;
            ToolTip = "Dismiss";
            MouseLeftButtonUp += (_, _) => Services.AppServices.Transfers.Dismiss(job.Id);
        }
    }

    /// <summary>Second line: the error, the result, "Waiting for a connection (Wi-Fi only?)" or "Unpacking {file}".</summary>
    public static string? Detail(TransferJob job)
    {
        if (job.State == TransferState.Failed) return job.Error;
        if (job.Kind == TransferKind.Upload) return null;
        switch (job.State)
        {
            case TransferState.Succeeded:
                var parts = new List<string> { job.Count == 1 ? "1 file extracted" : $"{job.Count} files extracted" };
                if (!string.IsNullOrEmpty(job.ZipNote)) parts.Add(job.ZipNote);
                parts.Add("scanning library");
                return string.Join(" · ", parts);
            case TransferState.Waiting:
            case TransferState.Enqueued:
                return "Waiting for a connection (Wi-Fi only?)";
            case TransferState.Running:
                return string.IsNullOrEmpty(job.Current) ? null : job.Current == "Preparing…" ? job.Current : $"Unpacking {job.Current}";
            default:
                return null;
        }
    }
}
