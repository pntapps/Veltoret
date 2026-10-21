using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Veltoret.Core.Cast;

/// <summary>
/// Subtitles for the TV (Android CastSubtitles): Chromecasts read WebVTT, so sidecar SRT / ASS / SSA / VTT files are
/// parsed into cues and converted, shifted by the player's subtitle sync.
/// </summary>
public static class CastSubtitles
{
    /// <summary>One cue: start and end in microseconds, and its text (lines separated by '\n').</summary>
    public sealed record Line(long StartUs, long EndUs, string Text);

    /// <summary>WebVTT for <paramref name="lines"/>, shifted by <paramref name="offsetUs"/>; cues ending before 0 are dropped.</summary>
    public static string ToVtt(IEnumerable<Line> lines, long offsetUs = 0)
    {
        var sb = new StringBuilder("WEBVTT\n\n");
        foreach (var line in lines)
        {
            var start = line.StartUs + offsetUs;
            var end = line.EndUs + offsetUs;
            var text = line.Text.Trim().Replace("-->", "->");
            if (end <= 0 || text.Length == 0) continue;
            sb.Append(Time(Math.Max(0, start))).Append(" --> ").Append(Time(end)).Append('\n');
            // A blank line would end the cue early.
            sb.Append(string.Join("\n", SplitLines(text).Where(l => !string.IsNullOrWhiteSpace(l)))).Append("\n\n");
        }
        return sb.ToString();
    }

    /// <summary>"01:02:03.045"</summary>
    public static string Time(long us)
    {
        var ms = us / 1000;
        return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}:{2:00}.{3:000}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000);
    }

    /// <summary>Kotlin's String.lines(): splits on CRLF, LF and CR.</summary>
    private static string[] SplitLines(string text) => text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);

    // ---- Parsing sidecar files ------------------------------------------------------------------------

    /// <summary>Cues of a subtitle file by its extension (srt, ass, ssa, vtt); others are tried as SRT.</summary>
    public static List<Line> Parse(string text, string fileName)
    {
        var ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant();
        if (text.Length > 0 && text[0] == '﻿') text = text[1..];
        return ext switch
        {
            "ass" or "ssa" => ParseAss(text),
            "vtt" => ParseSrtOrVtt(text),
            _ => ParseSrtOrVtt(text),
        };
    }

    /// <summary>Decodes subtitle bytes: UTF-8 (with or without BOM), UTF-16 with BOM, else Windows-1252.</summary>
    public static string Decode(byte[] bytes)
    {
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.Latin1.GetString(bytes);
        }
    }

    private static readonly Regex Timing = new(
        @"^\s*((?:[0-9]+:)?[0-9]{1,2}:[0-9]{1,2}[,.][0-9]{1,3})\s*-->\s*((?:[0-9]+:)?[0-9]{1,2}:[0-9]{1,2}[,.][0-9]{1,3})",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static readonly Regex Tags = new(@"<[^>]*>", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static List<Line> ParseSrtOrVtt(string text)
    {
        var lines = SplitLines(text);
        var cues = new List<Line>();
        for (var i = 0; i < lines.Length; i++)
        {
            var m = Timing.Match(lines[i]);
            if (!m.Success) continue;
            var start = Clock(m.Groups[1].Value);
            var end = Clock(m.Groups[2].Value);
            var body = new List<string>();
            var j = i + 1;
            for (; j < lines.Length && lines[j].Trim().Length > 0; j++)
            {
                if (Timing.IsMatch(lines[j])) { j--; break; }
                body.Add(Tags.Replace(lines[j], "").Trim());
            }
            i = Math.Max(i, j);
            if (start != null && end != null) cues.Add(new Line(start.Value, end.Value, string.Join("\n", body)));
        }
        cues.Sort((a, b) => a.StartUs.CompareTo(b.StartUs));
        return cues;
    }

    /// <summary>"01:02:03,045", "02:03.045" or "1:02:03.04" in microseconds.</summary>
    private static long? Clock(string text)
    {
        var parts = text.Replace(',', '.').Split(':');
        try
        {
            long h = 0, m, s;
            string secPart;
            if (parts.Length == 3) { h = long.Parse(parts[0], CultureInfo.InvariantCulture); m = long.Parse(parts[1], CultureInfo.InvariantCulture); secPart = parts[2]; }
            else if (parts.Length == 2) { m = long.Parse(parts[0], CultureInfo.InvariantCulture); secPart = parts[1]; }
            else return null;
            var dot = secPart.IndexOf('.');
            s = long.Parse(dot >= 0 ? secPart[..dot] : secPart, CultureInfo.InvariantCulture);
            long frac = 0;
            if (dot >= 0)
            {
                var f = secPart[(dot + 1)..];
                // ".5" = 500 ms, ".04" = 40 ms (centiseconds in ASS), ".045" = 45 ms.
                frac = long.Parse(f.PadRight(3, '0')[..3], CultureInfo.InvariantCulture);
            }
            return ((h * 3600 + m * 60 + s) * 1000 + frac) * 1000;
        }
        catch (FormatException) { return null; }
        catch (OverflowException) { return null; }
    }

    private static readonly Regex AssOverrides = new(@"\{[^}]*\}", RegexOptions.CultureInvariant | RegexOptions.Compiled);

    private static List<Line> ParseAss(string text)
    {
        var cues = new List<Line>();
        string[]? format = null;
        var inEvents = false;
        foreach (var raw in SplitLines(text))
        {
            var line = raw.Trim();
            if (line.StartsWith('['))
            {
                inEvents = line.Equals("[Events]", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!inEvents) continue;
            if (line.StartsWith("Format:", StringComparison.OrdinalIgnoreCase))
            {
                format = line["Format:".Length..].Split(',').Select(f => f.Trim().ToLowerInvariant()).ToArray();
                continue;
            }
            if (!line.StartsWith("Dialogue:", StringComparison.OrdinalIgnoreCase)) continue;
            format ??= new[] { "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text" };
            var fields = line["Dialogue:".Length..].Split(',', format.Length);
            if (fields.Length < format.Length) continue;
            var startAt = Array.IndexOf(format, "start");
            var endAt = Array.IndexOf(format, "end");
            var textAt = Array.IndexOf(format, "text");
            if (startAt < 0 || endAt < 0 || textAt < 0) continue;
            var start = Clock(fields[startAt].Trim());
            var end = Clock(fields[endAt].Trim());
            if (start == null || end == null) continue;
            var body = AssOverrides.Replace(fields[textAt], "")
                .Replace("\\N", "\n").Replace("\\n", "\n").Replace("\\h", " ");
            cues.Add(new Line(start.Value, end.Value, body));
        }
        cues.Sort((a, b) => a.StartUs.CompareTo(b.StartUs));
        return cues;
    }

    /// <summary>"Movie.en.srt" → "en"; null when the name has no language part.</summary>
    public static string? LanguageFromName(string fileName)
    {
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var dot = stem.LastIndexOf('.');
        if (dot < 0) return null;
        var tag = stem[(dot + 1)..].ToLowerInvariant();
        if (tag is "forced" or "sdh" or "cc" or "hi")
        {
            var rest = stem[..dot];
            var d2 = rest.LastIndexOf('.');
            if (d2 < 0) return null;
            tag = rest[(d2 + 1)..].ToLowerInvariant();
        }
        return tag.Length is 2 or 3 && tag.All(char.IsAsciiLetterLower) ? tag : null;
    }
}
