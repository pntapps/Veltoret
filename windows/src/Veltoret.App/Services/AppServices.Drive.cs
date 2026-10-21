using Veltoret.App.Navigation;
using Veltoret.App.Pages.Files;
using Veltoret.Core;
using Veltoret.Core.Auth;
using Veltoret.Core.Drive;

namespace Veltoret.App.Services;

// [drive] module wiring: Google sign-in, the Drive file source, uploads and ZIP extraction, Files and Archives pages.
public static partial class AppServices
{
    public static GoogleAuthService GoogleAuth { get; private set; } = null!;
    public static DriveRepository Drive { get; private set; } = null!;
    /// <summary>Uploads to Drive and ZIP extraction jobs (saved in transfers.json, resumed at start).</summary>
    public static TransferService Transfers { get; private set; } = null!;
    public static DriveFileSource DriveFiles { get; private set; } = null!;

    static partial void InitDrive()
    {
        var authHttp = new HttpClient(new SocketsHttpHandler { ConnectTimeout = TimeSpan.FromSeconds(20) })
        {
            Timeout = TimeSpan.FromSeconds(60),
        };
        GoogleAuth = new GoogleAuthService(authHttp, new DpapiSecretStore(AppPaths.Secrets), AccountDao);
        Drive = new DriveRepository(DriveRepository.CreateHttpClient(GoogleAuth));
        DriveFiles = new DriveFileSource(Drive);
        Storage.Register(DriveFiles);

        Transfers = new TransferService(Drive, Path.Combine(AppPaths.Root, "transfers.json"))
        {
            IsOnline = () => Connectivity?.IsOnline ?? true,
            IsUnmetered = () => !(Connectivity?.IsMetered ?? false),
            // A new folder full of videos: an automatic library rescan (queued behind a running scan).
            AfterExtraction = () =>
            {
                _ = Scans?.RunNow();
                return Task.CompletedTask;
            },
            ForgetArchive = id => Library?.ForgetArchive(id) ?? MediaFileDao.DeleteArchive(id),
        };

        Navigator.Register<FilesRoute>(r => new FilesPage(r.Account, r.FolderId));
        Navigator.Register<ArchivesRoute>(_ => new ArchivesPage());
    }

    static partial void StartDrive()
    {
        if (Transfers.HasPending) Transfers.Resume();
    }
}
