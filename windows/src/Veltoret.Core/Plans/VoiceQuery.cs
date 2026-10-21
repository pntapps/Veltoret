using System.Text.RegularExpressions;
using Veltoret.Core.Library;

namespace Veltoret.Core.Plans;

/// <summary>
/// Turns what someone said ("play Below season 1 episode 2 on Veltoret") into a library title (Android:
/// data/library/VoiceQuery.kt; VoiceQueryTest). Matching ignores case, accents, punctuation and a leading "the"
/// (<see cref="FilenameParser.NormalizeForCompare"/>), because speech never says "Spider-Man" with its hyphen.
/// </summary>
public static class VoiceQuery
{
    public sealed record Parsed(string Title, int? Season = null, int? Episode = null, int? Year = null);

    /// <summary>A movie or show in the library.</summary>
    public sealed record Candidate(int Id, bool IsShow, string Title, int? Year);

    private const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private static readonly Regex SeasonEpisode = new(@"\bseason\s+([0-9]{1,2})\s*,?\s*(?:episode|ep)\s+([0-9]{1,3})\b", I);
    private static readonly Regex Code = new(@"\bs([0-9]{1,2})\s*e([0-9]{1,3})\b", I);
    private static readonly Regex EpisodeOnly = new(@"\b(?:episode|ep)\s+([0-9]{1,3})\b", I);
    private static readonly Regex YearRx = new(@"\b(19[0-9][0-9]|20[0-9][0-9])\b", RegexOptions.CultureInvariant);
    private static readonly Regex Leading = new(@"^\s*(?:play|watch|start|resume|search(?:\s+for)?|find|open)\s+", I);
    private static readonly Regex Trailing = new(@"\s+(?:on|in|with|using)\s+veltoret\s*$", I);
    private static readonly Regex Spaces = new(@"\s+", RegexOptions.CultureInvariant);

    private const int MinScore = 40;

    public static Parsed Parse(string raw)
    {
        var text = Leading.Replace(Trailing.Replace(raw.Trim(), ""), "");
        int? season = null, episode = null;
        var m = SeasonEpisode.Match(text);
        if (!m.Success) m = Code.Match(text);
        if (m.Success)
        {
            season = int.Parse(m.Groups[1].Value);
            episode = int.Parse(m.Groups[2].Value);
            text = text.Remove(m.Index, m.Length);
        }
        else if (EpisodeOnly.Match(text) is { Success: true } e)
        {
            season = 1;
            episode = int.Parse(e.Groups[1].Value);
            text = text.Remove(e.Index, e.Length);
        }
        // A year narrows the match ("Dune 2021"), but a title that is only a year ("1917") stays a title.
        int? year = null;
        var ym = YearRx.Match(text);
        if (ym.Success)
        {
            var without = text.Remove(ym.Index, ym.Length);
            if (!string.IsNullOrWhiteSpace(without))
            {
                year = int.Parse(ym.Value);
                text = without;
            }
        }
        return new Parsed(Spaces.Replace(text, " ").Trim(), season, episode, year);
    }

    /// <summary>The title <paramref name="parsed"/> most likely means, or null when nothing is close enough to play.</summary>
    public static Candidate? Best(Parsed parsed, IReadOnlyList<Candidate> candidates)
    {
        var wanted = FilenameParser.NormalizeForCompare(parsed.Title);
        if (wanted.Length == 0) return null;
        var pool = parsed.Episode != null ? candidates.Where(c => c.IsShow) : candidates;
        Candidate? best = null;
        var bestScore = 0;
        foreach (var c in pool)
        {
            var s = Score(wanted, parsed.Year, c);
            if (s < MinScore) continue;
            // Ties: a movie (people say "play X" for films more often), then the shorter title; full ties keep the first.
            if (best == null || Compare(s, c, bestScore, best) > 0)
            {
                best = c;
                bestScore = s;
            }
        }
        return best;
    }

    private static int Compare(int s1, Candidate c1, int s2, Candidate c2)
    {
        if (s1 != s2) return s1.CompareTo(s2);
        if (c1.IsShow != c2.IsShow) return (!c1.IsShow).CompareTo(!c2.IsShow);
        return (-c1.Title.Length).CompareTo(-c2.Title.Length);
    }

    private static int Score(string wanted, int? year, Candidate c)
    {
        var title = FilenameParser.NormalizeForCompare(c.Title);
        if (title.Length == 0) return 0;
        int b;
        if (title == wanted) b = 100;
        else if (title.StartsWith(wanted + " ", StringComparison.Ordinal) || wanted.StartsWith(title + " ", StringComparison.Ordinal)) b = 80;
        else if (title.Contains(wanted, StringComparison.Ordinal) && wanted.Length >= 4) b = 65;
        else
        {
            // Most of the spoken words appear in the title ("wrecking crew" for "The Wrecking Crew").
            var words = wanted.Split(' ').Where(w => w.Length > 1).ToHashSet(StringComparer.Ordinal);
            var have = title.Split(' ').ToHashSet(StringComparer.Ordinal);
            if (words.Count == 0) b = 0;
            else
            {
                var s = 50 * words.Count(have.Contains) / words.Count;
                b = s >= 35 ? s : 0;
            }
        }
        var yearBonus = year == null || c.Year == null ? 0 : year == c.Year ? 10 : -20;
        return b + yearBonus;
    }
}
