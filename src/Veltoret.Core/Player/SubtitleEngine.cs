using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Veltoret.Core.Player;

/// <summary>One subtitle line (or block of lines) with a concrete start and end.</summary>
public sealed record SubtitleCue(long StartMs, long EndMs, string Text);

/// <summary>A message meant for the user ("That file is too large to be a subtitle").</summary>
public sealed class SubtitleException(string message) : Exception(message);

/// <summary>
/// Subtitle files Veltoret loads itself (Android: SubtitleEngine). libVLC renders them (with libass for ASS), but
/// the bytes are normalised to UTF-8 first and parsed once here, to report "No subtitles found in …" and to keep
/// the same cue rules as the Android app.
/// </summary>
public static class SubtitleEngine
{
    /// <summary>Larger files are almost certainly not text subtitles.</summary>
    public const int MaxBytes = 8 * 1024 * 1024;

    public const string TooLarge = "That file is too large to be a subtitle";

    public enum Kind { SubRip, WebVtt, Ssa, Ttml }

    static SubtitleEngine()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static Kind FormatOf(string fileName) => Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant() switch
    {
        "vtt" => Kind.WebVtt,
        "ass" or "ssa" => Kind.Ssa,
        "ttml" or "dfxp" => Kind.Ttml,
        _ => Kind.SubRip,
    };

    /// <summary>Reads at most <see cref="MaxBytes"/>, failing with the user-facing message when larger.</summary>
    public static async Task<byte[]> ReadLimited(Stream stream, CancellationToken ct = default)
    {
        using var ms = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var n = await stream.ReadAsync(buffer, ct);
            if (n <= 0) break;
            ms.Write(buffer, 0, n);
            if (ms.Length > MaxBytes) throw new SubtitleException(TooLarge);
        }
        return ms.ToArray();
    }

    // ---- Text encoding --------------------------------------------------------------------------

    /// <summary>
    /// Android's normalizeText: UTF-8/UTF-16 with a BOM and valid UTF-8 are kept; anything else is a legacy
    /// code page, guessed and transcoded to UTF-8.
    /// </summary>
    public static byte[] NormalizeText(byte[] bytes)
    {
        if (HasUtf8Bom(bytes) || HasUtf16Bom(bytes)) return bytes;
        if (IsStrictUtf8(bytes)) return bytes;
        var text = GuessLegacyEncoding(bytes).GetString(bytes);
        return new UTF8Encoding(false).GetBytes(text);
    }

    /// <summary>The file as text (BOMs honoured, legacy code pages guessed).</summary>
    public static string DecodeText(byte[] bytes)
    {
        var normalized = NormalizeText(bytes);
        if (HasUtf8Bom(normalized)) return Encoding.UTF8.GetString(normalized, 3, normalized.Length - 3);
        if (normalized.Length >= 2 && normalized[0] == 0xFF && normalized[1] == 0xFE) return Encoding.Unicode.GetString(normalized, 2, normalized.Length - 2);
        if (normalized.Length >= 2 && normalized[0] == 0xFE && normalized[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(normalized, 2, normalized.Length - 2);
        return new UTF8Encoding(false).GetString(normalized);
    }

    /// <summary>UTF-8 with a BOM: what Veltoret writes to the temporary file it hands to libVLC.</summary>
    public static byte[] ToUtf8WithBom(byte[] bytes)
    {
        var text = DecodeText(bytes);
        return Encoding.UTF8.GetPreamble().Concat(new UTF8Encoding(false).GetBytes(text)).ToArray();
    }

    private static bool HasUtf8Bom(byte[] b) => b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;

    private static bool HasUtf16Bom(byte[] b) => b.Length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF));

    private static bool IsStrictUtf8(byte[] bytes)
    {
        try
        {
            new UTF8Encoding(false, throwOnInvalidBytes: true).GetCharCount(bytes);
            return true;
        }
        catch (DecoderFallbackException)
        {
            return false;
        }
    }

    /// <summary>
    /// Light heuristic for legacy single-byte encodings. Western text is mostly ASCII letters with the odd accent;
    /// Cyrillic and Arabic text is mostly high bytes, told apart by their most frequent letters.
    /// </summary>
    public static Encoding GuessLegacyEncoding(byte[] bytes)
    {
        int asciiLetters = 0, high = 0, cyrillic = 0, arabic = 0;
        foreach (var v in bytes)
        {
            if (v < 0x80)
            {
                if (v is >= 0x41 and <= 0x5A or >= 0x61 and <= 0x7A) asciiLetters++;
                continue;
            }
            high++;
            if (v is 0xE0 or 0xE5 or 0xE8 or 0xED or 0xEE or >= 0xF0 and <= 0xF2) cyrillic++;
            if (v is 0xC7 or 0xC8 or 0xCA or 0xD1 or 0xE1 or 0xE3 or 0xE4 or 0xE6) arabic++;
        }
        var nonLatin = high > 0 && (float)high / (high + asciiLetters) > 0.3f;
        var codePage = !nonLatin ? 1252 : arabic > cyrillic ? 1256 : 1251;
        try
        {
            return Encoding.GetEncoding(codePage, EncoderFallback.ReplacementFallback, DecoderFallback.ReplacementFallback);
        }
        catch (Exception)
        {
            return Encoding.Latin1;
        }
    }

    // ---- Parsing ----------------------------------------------------------------------------------

    /// <summary>Parses a subtitle file into cues (sorted, with concrete ends, empty ones dropped).</summary>
    public static List<SubtitleCue> Parse(byte[] bytes, string fileName)
    {
        if (bytes.Length > MaxBytes) throw new SubtitleException(TooLarge);
        var text = DecodeText(bytes).Replace("\r\n", "\n").Replace('\r', '\n');
        List<(long? Start, long? End, string Text)> raw;
        try
        {
            raw = FormatOf(fileName) switch
            {
                Kind.Ssa => ParseSsa(text),
                Kind.Ttml => ParseTtml(text),
                _ => ParseArrows(text),
            };
        }
        catch (System.Xml.XmlException)
        {
            throw new SubtitleException("This subtitle format isn't supported");
        }
        return Finish(raw);
    }

    private static List<SubtitleCue> Finish(List<(long? Start, long? End, string Text)> raw)
    {
        var sorted = raw.Where(c => c.Start != null).OrderBy(c => c.Start!.Value).ToList();
        var cues = new List<SubtitleCue>(sorted.Count);
        for (var i = 0; i < sorted.Count; i++)
        {
            var c = sorted[i];
            var start = c.Start!.Value;
            // Some formats leave the end open ("until the next cue").
            var end = c.End ?? (i + 1 < sorted.Count ? sorted[i + 1].Start!.Value : start + 5_000);
            var t = c.Text.Trim();
            if (t.Length > 0) cues.Add(new SubtitleCue(start, end, t));
        }
        return cues;
    }

    /// <summary>Cues to show at <paramref name="positionMs"/> after the user's sync offset (positive = later).</summary>
    public static List<SubtitleCue> ActiveAt(IReadOnlyList<SubtitleCue> cues, long positionMs, long offsetMs)
    {
        var t = positionMs - offsetMs;
        int lo = 0, hi = cues.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) >>> 1;
            if (cues[mid].StartMs <= t) lo = mid + 1;
            else hi = mid;
        }
        var result = new List<SubtitleCue>(2);
        for (int i = lo - 1, scanned = 0; i >= 0 && scanned < 64; i--, scanned++)
        {
            if (t < cues[i].EndMs) result.Insert(0, cues[i]);
        }
        return result;
    }

    private static readonly Regex Timestamp = new(@"(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?", RegexOptions.CultureInvariant);
    private static readonly Regex Tags = new(@"<[^>]*>|\{\\[^}]*\}", RegexOptions.CultureInvariant);

    private static long? ParseClock(string s)
    {
        var m = Timestamp.Match(s.Trim());
        if (!m.Success) return null;
        long h = m.Groups[1].Success ? long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
        long min = long.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        long sec = long.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture);
        long ms = 0;
        if (m.Groups[4].Success)
        {
            var f = m.Groups[4].Value;
            ms = long.Parse(f, CultureInfo.InvariantCulture) * (f.Length == 1 ? 100 : f.Length == 2 ? 10 : 1);
        }
        return ((h * 60 + min) * 60 + sec) * 1000 + ms;
    }

    /// <summary>SubRip and WebVTT: a "start --> end" line followed by text until a blank line.</summary>
    private static List<(long?, long?, string)> ParseArrows(string text)
    {
        var result = new List<(long?, long?, string)>();
        var lines = text.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var arrow = line.IndexOf("-->", StringComparison.Ordinal);
            if (arrow < 0) continue;
            var start = ParseClock(line[..arrow]);
            var endPart = line[(arrow + 3)..].Trim();
            var space = endPart.IndexOfAny(new[] { ' ', '\t' });
            var end = ParseClock(space < 0 ? endPart : endPart[..space]);
            var body = new StringBuilder();
            var j = i + 1;
            for (; j < lines.Length && lines[j].Trim().Length > 0; j++)
            {
                if (lines[j].Contains("-->", StringComparison.Ordinal)) break;
                if (body.Length > 0) body.Append('\n');
                body.Append(lines[j].Trim());
            }
            i = j - 1;
            result.Add((start, end, Tags.Replace(body.ToString(), "")));
        }
        return result;
    }

    /// <summary>SSA/ASS: "Dialogue:" lines in [Events], fields named by the "Format:" line.</summary>
    private static List<(long?, long?, string)> ParseSsa(string text)
    {
        var result = new List<(long?, long?, string)>();
        string[]? format = null;
        var inEvents = false;
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.StartsWith('['))
            {
                inEvents = line.Equals("[Events]", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!inEvents) continue;
            if (line.StartsWith("Format:", StringComparison.OrdinalIgnoreCase))
            {
                format = line[7..].Split(',').Select(f => f.Trim().ToLowerInvariant()).ToArray();
                continue;
            }
            if (!line.StartsWith("Dialogue:", StringComparison.OrdinalIgnoreCase)) continue;
            format ??= new[] { "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text" };
            var fields = line[9..].Split(',', format.Length);
            if (fields.Length < format.Length) continue;
            var startIdx = Array.IndexOf(format, "start");
            var endIdx = Array.IndexOf(format, "end");
            var textIdx = Array.IndexOf(format, "text");
            if (startIdx < 0 || textIdx < 0) continue;
            var body = Tags.Replace(fields[textIdx], "").Replace("\\N", "\n").Replace("\\n", "\n").Replace("\\h", " ");
            result.Add((ParseClock(fields[startIdx]), endIdx >= 0 ? ParseClock(fields[endIdx]) : null, body));
        }
        return result;
    }

    /// <summary>TTML/DFXP: &lt;p begin end|dur&gt; elements; times as clock values or offsets ("12.5s", "500ms").</summary>
    private static List<(long?, long?, string)> ParseTtml(string text)
    {
        var doc = XDocument.Parse(text);
        var result = new List<(long?, long?, string)>();
        foreach (var p in doc.Descendants().Where(e => e.Name.LocalName == "p"))
        {
            var begin = TtmlTime(Attr(p, "begin"));
            var end = TtmlTime(Attr(p, "end"));
            var dur = TtmlTime(Attr(p, "dur"));
            if (end == null && begin != null && dur != null) end = begin + dur;
            var body = new StringBuilder();
            foreach (var node in p.DescendantNodes())
            {
                if (node is XText t) body.Append(t.Value);
                else if (node is XElement { Name.LocalName: "br" }) body.Append('\n');
            }
            result.Add((begin, end, body.ToString()));
        }
        return result;
    }

    private static string? Attr(XElement e, string name) => e.Attributes().FirstOrDefault(a => a.Name.LocalName == name)?.Value;

    private static long? TtmlTime(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var v = value.Trim();
        var offset = Regex.Match(v, @"^([0-9.]+)(h|m|s|ms|f|t)$", RegexOptions.CultureInvariant);
        if (offset.Success && double.TryParse(offset.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var n))
        {
            return offset.Groups[2].Value switch
            {
                "h" => (long)(n * 3_600_000),
                "m" => (long)(n * 60_000),
                "s" => (long)(n * 1000),
                "ms" => (long)n,
                "f" => (long)(n * 1000 / 30),
                _ => (long)(n / 10_000), // ticks at 10 MHz
            };
        }
        // hh:mm:ss:frames → drop the frames part
        var parts = v.Split(':');
        if (parts.Length == 4) v = string.Join(':', parts.Take(3));
        return ParseClock(v);
    }
}
