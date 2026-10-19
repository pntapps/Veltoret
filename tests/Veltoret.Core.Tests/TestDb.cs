using Microsoft.Data.Sqlite;
using Veltoret.Core.Data;

namespace Veltoret.Core.Tests;

/// <summary>A throwaway database file for one test.</summary>
public sealed class TestDb : IDisposable
{
    public string Dir { get; } = Path.Combine(Path.GetTempPath(), "veltoret-tests", Guid.NewGuid().ToString("N"));
    public VeltoretDb Db { get; }
    public AccountDao Accounts { get; }
    public MediaFileDao Files { get; }
    public CatalogDao Catalog { get; }
    public WatchDao Watch { get; }

    public TestDb()
    {
        Directory.CreateDirectory(Dir);
        Db = new VeltoretDb(Path.Combine(Dir, "test.db"));
        Accounts = new AccountDao(Db);
        Files = new MediaFileDao(Db);
        Catalog = new CatalogDao(Db);
        Watch = new WatchDao(Db);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try { Directory.Delete(Dir, recursive: true); }
        catch { }
    }
}
