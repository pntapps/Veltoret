namespace Veltoret.Core.Library;

/// <summary>"More like this": TMDB's recommendations for a title, narrowed to the ones in the library.</summary>
public static class RelatedTitles
{
    public const int Limit = 20;

    /// <summary>Parses RecommendationEntity.RecommendedIds.</summary>
    public static List<int> ParseIds(string? csv)
    {
        var list = new List<int>();
        foreach (var part in (csv ?? "").Split(','))
        {
            if (int.TryParse(part.Trim(), System.Globalization.NumberStyles.AllowLeadingSign,
                    System.Globalization.CultureInfo.InvariantCulture, out var n)) list.Add(n);
        }
        return list;
    }

    /// <summary>The recommended titles found in <paramref name="library"/>, in TMDB's order, without <paramref name="selfId"/> or repeats.</summary>
    public static List<T> InLibrary<T>(IEnumerable<int> recommended, IReadOnlyDictionary<int, T> library, int selfId, int limit = Limit) =>
        recommended
            .Where(id => id != selfId)
            .Distinct()
            .Where(library.ContainsKey)
            .Select(id => library[id])
            .Take(limit)
            .ToList();
}
