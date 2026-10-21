using Veltoret.Core;
using Veltoret.Core.Player;

namespace Veltoret.App.Player;

/// <summary>
/// Track memory and per-show languages (Android PlayerPrefs), stored in <see cref="AppPaths.PlayerPrefs"/>.
/// The logic lives in <see cref="PlayerPrefsStore"/> (Veltoret.Core, unit-tested).
/// </summary>
public sealed class PlayerPrefs : PlayerPrefsStore
{
    private static readonly Lazy<PlayerPrefs> Instance = new(() => new PlayerPrefs(AppPaths.PlayerPrefs));

    public static PlayerPrefs Shared => Instance.Value;

    public PlayerPrefs(string path) : base(path)
    {
    }
}
