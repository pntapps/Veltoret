namespace Veltoret.Core.Tmdb;

/// <summary>TMDB image URLs. Keep sizes in step with ArtworkPrefetch so artwork is cached for offline use.</summary>
public static class TmdbImages
{
    private const string Base = "https://image.tmdb.org/t/p/";
    public static string? Poster(string? path, string size = "w342") => path == null ? null : Base + size + path;
    public static string? Backdrop(string? path, string size = "w1280") => path == null ? null : Base + size + path;
    public static string? Still(string? path, string size = "w300") => path == null ? null : Base + size + path;
    public static string? Profile(string? path, string size = "w185") => path == null ? null : Base + size + path;
}
