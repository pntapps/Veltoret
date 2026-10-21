namespace Veltoret.Core;

/// <summary>Where Veltoret keeps its data: %LOCALAPPDATA%\Veltoret (never roamed: libraries can be large).</summary>
public static class AppPaths
{
    public static string Root { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Veltoret");

    public static string Database => Path.Combine(Root, "veltoret.db");
    public static string Settings => Path.Combine(Root, "settings.json");
    /// <summary>Poster and backdrop cache, so the library looks right offline.</summary>
    public static string ImageCache => Path.Combine(Root, "images");
    /// <summary>Per-video track choices and per-show languages (player).</summary>
    public static string PlayerPrefs => Path.Combine(Root, "player-prefs.json");
    /// <summary>Google tokens and SMB passwords, encrypted with DPAPI (current Windows user).</summary>
    public static string Secrets => Path.Combine(Root, "secrets");
    public static string Logs => Path.Combine(Root, "logs");
}
