import Foundation
import VeltoretKit

/// VeltoretCast module entry points (called by the app target).
public enum VeltoretCastModule {
    public static func initialize() {
        let store = TvLinkStore(url: TvLinkStore.defaultURL, secrets: AppServices.secrets)
        AppServices.tvLinks = store
        let open: CastServer.Opener = { account, fileId in try await AppServices.storage.openRead(account, id: fileId) }
        let factory = CastMediaFactory(
            files: AppServices.mediaFileDao, catalog: AppServices.catalogDao, openRead: open,
            preferredSubtitleLanguage: { AppServices.settings.current.preferredSubtitleLanguage },
            preferredAudioLanguage: { AppServices.settings.current.preferredAudioLanguage })
        AppServices.cast = CastController(open: open, tvLink: TvLinkClient(store: store), progress: WatchProgressStore(),
                                          media: factory, autoPlayNext: { AppServices.settings.current.autoPlayNext })
    }

    public static func start() {}

    public static func shutdown() {
        AppServices.cast?.shutdown()
    }
}
