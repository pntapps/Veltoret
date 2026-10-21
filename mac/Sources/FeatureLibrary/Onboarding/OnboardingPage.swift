import SwiftUI
import VeltoretKit
import VeltoretUI

/// First-run setup (Windows OnboardingPage, Android OnboardingScreen): Welcome → Accounts → Folders → TMDB → Scan.
/// Back works on steps 1–3. Finishing (either button on the Scan step) sets onboardingComplete and opens Home.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int { case welcome, accounts, folders, tmdb, scan }
    enum KeyStatus { case none, checking, valid, invalid }

    @Published private(set) var step: Step = .welcome
    @Published private(set) var forward = true
    @Published private(set) var accounts: [AccountEntity] = []
    @Published private(set) var folders: [LibraryFolderEntity] = []
    @Published private(set) var connecting = false
    @Published private(set) var connectError: String?
    @Published var useOwnKey: Bool
    @Published var key: String { didSet { if key != oldValue { keyStatus = .none; keyError = nil } } }
    @Published var showKey = false
    @Published private(set) var keyStatus: KeyStatus = .none
    @Published private(set) var keyError: String?
    @Published private(set) var scan = ScanState()
    private let bag = SubscriptionBag()
    private var started = false

    init() {
        key = AppServices.settings?.current.tmdbKeyOverride ?? ""
        useOwnKey = BundledKeys.tmdb.isEmpty
    }

    deinit { bag.cancelAll() }

    var hasBundledKey: Bool { !BundledKeys.tmdb.isEmpty }
    var canGoBack: Bool { step == .accounts || step == .folders || step == .tmdb }
    var finished: Bool { !scan.running && scan.lastFinishedAt > 0 }

    func start() {
        guard !started else { return }
        started = true
        if let scanner = AppServices.scanner {
            scan = scanner.state
            bag.add(scanner.stateChanged.subscribe { [weak self] s in Task { @MainActor in self?.scan = s } })
        }
        if let db = AppServices.db {
            bag.add(db.changed.subscribe { [weak self] tables in
                guard tables.contains("accounts") || tables.contains("library_folders") else { return }
                Task { @MainActor in self?.reloadSources() }
            })
        }
        reloadSources()
    }

    func reloadSources() {
        Task {
            let (a, f) = await Task.detached { () -> ([AccountEntity], [LibraryFolderEntity]) in
                ((try? AppServices.library?.accountList()) ?? [], (try? AppServices.library?.folders()) ?? [])
            }.value
            accounts = a
            folders = f
        }
    }

    func go(_ s: Step) {
        forward = s.rawValue >= step.rawValue
        withAnimation(.easeOut(duration: 0.42)) { step = s }
    }

    func next() { if let s = Step(rawValue: step.rawValue + 1) { go(s) } }
    func back() { if canGoBack, let s = Step(rawValue: step.rawValue - 1) { go(s) } }

    // MARK: Accounts

    func connectGoogle() {
        guard !connecting else { return }
        guard let hook = LibraryHooks.connectGoogle else { connectError = "Google sign-in isn't available in this build."; return }
        connecting = true
        connectError = nil
        Task {
            _ = await hook()
            connecting = false
            reloadSources()
        }
    }

    func useLocal() {
        Task {
            do { try await Task.detached { try AppServices.library?.ensureDeviceAccount() }.value } catch { Toast.show(error.localizedDescription) }
            reloadSources()
        }
    }

    func addServer() {
        guard let hook = LibraryHooks.addNetworkServer else { Toast.show("Network servers aren't available"); return }
        Task {
            _ = await hook()
            reloadSources()
        }
    }

    // MARK: Folders

    func addFolder(_ account: String) {
        Task {
            guard let picked = await FolderPicker.pickLibraryFolder(account: account) else { return }
            do {
                let id = try await Task.detached {
                    try AppServices.library?.addFolder(account: account, folderId: picked.id, name: picked.name, type: picked.type)
                }.value
                if id == nil { Toast.show("That folder is already in your library") }
            } catch {
                Toast.show(error.localizedDescription)
            }
            reloadSources()
        }
    }

    func removeFolder(_ id: Int64) {
        Task {
            try? await Task.detached { try AppServices.library?.removeFolder(id) }.value
            reloadSources()
        }
    }

    // MARK: TMDB

    func verifyKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, let tmdb = AppServices.tmdb else { return }
        keyStatus = .checking
        Task {
            AppServices.settings?.update { $0.tmdbKeyOverride = k }
            do {
                try await tmdb.validateKey()
                keyStatus = .valid
            } catch let e as TmdbError where e.statusCode == 401 {
                keyStatus = .invalid
                keyError = "TMDB didn't accept this key. Copy it again from your TMDB account."
            } catch {
                keyStatus = .invalid
                let msg = (error as? TmdbError)?.message ?? (error is URLError ? "" : error.localizedDescription)
                keyError = msg.trimmingCharacters(in: .whitespaces).isEmpty ? "Couldn't reach TMDB. Check your connection." : msg
            }
        }
    }

    func buildLibrary() {
        if let scans = AppServices.scans {
            scans.start()
            Task.detached { await scans.runNow() }
        }
        if let scanner = AppServices.scanner { scan = scanner.state }
        go(.scan)
    }

    func finish() {
        AppServices.settings?.update { $0.onboardingComplete = true }
        bag.cancelAll()
        Navigator.shared.reset(to: .home)
    }
}

struct OnboardingPage: View {
    @StateObject private var model = OnboardingModel()

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900
            let maxW: CGFloat = wide ? 1200 : 640
            let inner = min(maxW, geo.size.width - (wide ? 96 : 48))
            let height = geo.size.height - 24
            ZStack {
                stepView(model.step, wide: wide, width: inner, height: height)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .offset(x: (model.forward ? 1 : -1) * inner / 3).combined(with: .opacity),
                        removal: .offset(x: (model.forward ? -1 : 1) * inner / 4).combined(with: .opacity)))
            }
            .frame(width: inner, height: height)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .vPageBackground()
        .onAppear { model.start() }
    }

    // MARK: Layout

    @ViewBuilder
    private func stepView(_ step: OnboardingModel.Step, wide: Bool, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if step != .welcome { TopProgress(index: step.rawValue, canGoBack: model.canGoBack) { model.back() }.padding(.bottom, 12) }
            let illuBox = wide ? CGSize(width: (width - 56) / 2, height: height - 80) : CGSize(width: width, height: min(240, height * 0.32))
            if wide {
                HStack(spacing: 56) {
                    illustration(step, box: illuBox)
                        .frame(width: illuBox.width)
                        .vEntrance(0)
                    rightColumn(step)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 20) {
                    illustration(step, box: illuBox).frame(height: illuBox.height).vEntrance(0)
                    rightColumn(step)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func rightColumn(_ step: OnboardingModel.Step) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                content(step).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            bottom(step).padding(.top, 16).padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func illustration(_ step: OnboardingModel.Step, box: CGSize) -> some View {
        switch step {
        case .welcome:
            PosterWallIllustration(size: max(120, min(560, box.width, box.height)))
        case .accounts:
            Fitted(natural: CGSize(width: 420, height: 210), box: box, maxWidth: 520) { ConnectIllustration(connected: !model.accounts.isEmpty) }
        case .folders:
            Fitted(natural: CGSize(width: 336, height: 200), box: box, maxWidth: 460) { FoldersIllustration() }
        case .tmdb:
            Fitted(natural: CGSize(width: 340, height: 210), box: box, maxWidth: 420) { MetadataIllustration() }
        case .scan:
            Fitted(natural: CGSize(width: 448, height: 330), box: box, maxWidth: 560) { ScanIllustration(finished: model.finished) }
                .id(model.finished)
        }
    }

    @ViewBuilder
    private func content(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome: welcome
        case .accounts: accountsStep
        case .folders: foldersStep
        case .tmdb: tmdbStep
        case .scan: scanStep
        }
    }

    @ViewBuilder
    private func bottom(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome:
            VStack(spacing: 12) {
                VButton("Get started", icon: "arrow.right", kind: .primary, fullWidth: true) { model.next() }.vEntrance(7)
                Text("Free and open source · Your files stay in your Drive and on your Mac")
                    .vBodySmall(Theme.textFaint).multilineTextAlignment(.center).vEntrance(8)
            }
        case .accounts:
            VButton("Continue", kind: .primary, fullWidth: true) { model.next() }.disabled(model.accounts.isEmpty)
        case .folders:
            VButton("Continue", kind: .primary, fullWidth: true) { model.next() }.disabled(model.folders.isEmpty)
        case .tmdb:
            if model.hasBundledKey && !model.useOwnKey {
                VButton("Build my library", kind: .primary, fullWidth: true) { model.buildLibrary() }
            } else {
                let valid = model.keyStatus == .valid
                VButton(valid ? "Build my library" : "Verify key", kind: .primary, loading: model.keyStatus == .checking,
                        fullWidth: true) {
                    if valid { model.buildLibrary() } else { model.verifyKey() }
                }
                .disabled(!valid && model.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .scan:
            if model.finished {
                VButton("Start watching", icon: "play.circle", kind: .primary, fullWidth: true) { model.finish() }
            } else {
                VButton("Continue in background", kind: .secondary, fullWidth: true) { model.finish() }
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(large: true).vEntrance(1)
            Text("Your movies and shows,\nas a private cinema.").vHeadlineMedium()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 24).vEntrance(2)
            feature("sparkles", "Organized for you", "Posters, cast and episode guides added automatically.").vEntrance(3)
            feature("play.circle", "Plays everything", "MKV, MP4 and more, with any audio track or subtitle.").vEntrance(4)
            feature("laptopcomputer.and.iphone", "Picks up where you left off", "Continue Watching and Next Up remember your place.").vEntrance(5)
        }
    }

    private func feature(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
                .vHairline(12)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Theme.amber))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).vTitleMedium()
                Text(body).vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private var accountsStep: some View {
        let google = model.accounts.filter { Accounts.isDrive($0.email) }
        return VStack(alignment: .leading, spacing: 0) {
            StepHeader(eyebrow: "Step 1 · Connect", title: "Where are your videos?",
                       text: "Connect the Google Drive that holds them, use folders on this Mac (internal or external drives), a network server (SMB) at home, or all of them. You can change this any time.")
            ForEach(model.accounts, id: \.email) { accountPanel($0).padding(.bottom, 10) }
            VStack(spacing: 10) {
                VButton(google.isEmpty ? "Connect Google account" : "Add another Google account", icon: "person.badge.plus",
                        kind: model.accounts.isEmpty ? .primary : .secondary, loading: model.connecting, fullWidth: true) {
                    model.connectGoogle()
                }
                if !model.accounts.contains(where: { Accounts.isLocal($0.email) }) {
                    VButton("Use folders on this Mac", icon: "desktopcomputer", kind: .secondary, fullWidth: true) { model.useLocal() }
                }
                if LibraryHooks.addNetworkServer != nil {
                    VButton("Add network server", icon: "server.rack", kind: .secondary, fullWidth: true) { model.addServer() }
                }
            }
            .padding(.top, 4)
            if let err = model.connectError {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Couldn't connect").vTitleMedium()
                    Text(err).vBodyMedium(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    Text("Google sign-in needs your own OAuth client (a “Desktop app” client JSON from Google Cloud Console). Import it in Settings → Accounts, then try again.")
                        .vBodySmall(Theme.textFaint).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                .vHairline(16, color: Theme.danger45)
                .padding(.top, 14)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 17)).foregroundStyle(Theme.amberSoft).frame(width: 20)
                Text("Private by design. Veltoret talks to Google and your network servers directly from this Mac and only sees the folders you pick — no servers of ours, no tracking. You can disconnect at any time in Settings.")
                    .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .padding(.top, 16)
        }
    }

    private static func libraryLabel(_ account: String) -> String {
        if Accounts.isLocal(account) { return Accounts.deviceDisplayName }
        if Accounts.isSmb(account) {
            return (try? AppServices.storage?.rootName(account)) ?? account.replacingOccurrences(of: "smb://", with: "")
        }
        return account
    }

    private static func accountLabel(_ a: AccountEntity) -> String {
        Accounts.isDrive(a.email) ? a.email : a.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? libraryLabel(a.email) : a.displayName
    }

    private func accountPanel(_ a: AccountEntity) -> some View {
        let initial = (a.displayName.isEmpty ? a.email : a.displayName).first.map { String($0).uppercased() } ?? "?"
        let name = Accounts.isDrive(a.email) && !a.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? a.displayName : Self.accountLabel(a)
        let sub = Accounts.isLocal(a.email) ? "Folders on this Mac" : Accounts.isSmb(a.email) ? "Network server" : a.email
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.surfaceHigh)
                Circle().strokeBorder(Theme.outline, lineWidth: 1)
                if Accounts.isLocal(a.email) {
                    Image(systemName: "desktopcomputer").font(.system(size: 17)).foregroundStyle(Theme.amberSoft)
                } else if Accounts.isSmb(a.email) {
                    Image(systemName: "server.rack").font(.system(size: 17)).foregroundStyle(Theme.amberSoft)
                } else if let photo = a.photoUrl, !photo.isEmpty {
                    ArtworkImage(url: photo, fallbackText: initial, cornerRadius: 20, maxPixel: 120).clipShape(Circle())
                } else {
                    Text(initial).vTitleMedium(Theme.amberSoft)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).vTitleMedium().lineLimit(1)
                Text(sub).vBodySmall(Theme.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.amber).help("Connected")
        }
        .vPanel(padding: 14)
    }

    private var foldersStep: some View {
        let multi = model.accounts.count > 1
        let anyFolders = !model.folders.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            StepHeader(eyebrow: "Step 2 · Library", title: "Choose your folders",
                       text: "Tell Veltoret where your movies and TV shows live. You can add several folders of each kind.")
            ForEach(Array(model.accounts.enumerated()), id: \.element.email) { index, a in
                if multi {
                    Text(Self.accountLabel(a)).vLabelLarge(Theme.textMuted).lineLimit(1)
                        .padding(.top, index > 0 ? 16 : 0).padding(.bottom, 8)
                }
                let mine = model.folders.filter { $0.accountEmail == a.email }
                ForEach(mine) { folderPanel($0).padding(.bottom, 10) }
                let name = Self.accountLabel(a)
                let text = !mine.isEmpty ? "Add another folder"
                    : Accounts.isLocal(a.email) ? (multi ? "Choose a folder on this Mac" : "Choose a folder")
                    : Accounts.isSmb(a.email) ? (multi ? "Choose a folder on \(name)" : "Choose a folder")
                    : multi ? "Choose a Drive folder" : "Choose a folder"
                VButton(text, icon: "folder.badge.plus", kind: anyFolders ? .secondary : .primary, fullWidth: true) {
                    model.addFolder(a.email)
                }
                .padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Works best like this").vTitleSmall()
                Text("Movies/\n  Inception (2010)/Inception.mkv\nTV Shows/\n  Breaking Bad/\n    Season 1/S01E01.mkv")
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(3).foregroundStyle(Theme.amberSoft)
                    .padding(.vertical, 10)
                Text("Messy names are fine too — anything Veltoret can't recognise can be fixed later in a couple of clicks.")
                    .vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            .vPanel()
            .padding(.top, 10)
        }
    }

    private func folderPanel(_ f: LibraryFolderEntity) -> some View {
        HStack(spacing: 0) {
            Image(systemName: f.type == .MOVIES ? "film" : "tv").font(.system(size: 18)).foregroundStyle(Theme.amber)
                .frame(width: 22).padding(.trailing, 12)
            Text(f.name).vTitleSmall().lineLimit(1).truncationMode(.middle).help(f.driveFolderId)
                .frame(maxWidth: .infinity, alignment: .leading)
            VPill(f.type == .MOVIES ? "Movies" : "TV Shows", style: .accent).padding(.horizontal, 8)
            VIconButton("xmark", help: "Remove", size: 32, kind: .flat) { model.removeFolder(f.id) }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
        .vHairline(Theme.Radius.card)
        .contextMenu {
            if Accounts.isLocal(f.accountEmail) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.driveFolderId)]) }
            }
            Button("Remove") { model.removeFolder(f.id) }
        }
    }

    @ViewBuilder
    private var tmdbStep: some View {
        if model.hasBundledKey && !model.useOwnKey {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(eyebrow: "Step 3 · Artwork", title: "Posters & details are ready",
                           text: "This copy of Veltoret comes with a TMDB key, so posters, cast and episode guides work without any setup.")
                VButton("Use my own TMDB key instead", icon: "key", kind: .text) { model.useOwnKey = true }
                    .fixedSize().padding(.leading, -8).padding(.bottom, 16)
                TmdbAttribution()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(eyebrow: "Step 3 · Artwork", title: "Add posters & details",
                           text: "Veltoret uses The Movie Database (TMDB) for posters, cast and episode guides. A free key takes about a minute.")
                ForEach(Array(["Create a free account at themoviedb.org",
                               "Open Settings → API and request a key (choose “Personal”)",
                               "Copy the API Key or the Read Access Token and paste it below"].enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .center, spacing: 12) {
                        Circle().fill(Theme.amberDim).frame(width: 26, height: 26)
                            .overlay(Text("\(i + 1)").vLabelMedium(Theme.amberSoft))
                        Text(s).vBodyMedium().fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 10)
                }
                VButton("Open TMDB API settings", icon: "arrow.up.forward.square", kind: .text) {
                    openInBrowser("https://www.themoviedb.org/settings/api")
                }
                .fixedSize().padding(.leading, -8).padding(.bottom, 14)
                VTextField("API key or Read Access Token", text: $model.key, icon: "key", secure: !model.showKey,
                           onSubmit: { if model.keyStatus != .valid { model.verifyKey() } }) {
                    VIconButton(model.showKey ? "eye.slash" : "eye", help: "Show key", size: 32, kind: .flat) { model.showKey.toggle() }
                }
                statusLine.padding(.top, 10)
                TmdbAttribution().padding(.top, 20)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.keyStatus {
        case .valid:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("Key verified — you're all set").vBodyMedium(Theme.success)
            }
        case .invalid:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.danger)
                Text(model.keyError ?? "").vBodyMedium(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        default:
            EmptyView()
        }
    }

    private var scanStep: some View {
        let s = model.scan
        let finished = model.finished
        return VStack(alignment: .leading, spacing: 0) {
            Text("STEP 4 · LIBRARY").vLabelSmall(Theme.amber).lineLimit(1)
            Text(finished ? "Your library is ready" : "Building your library").vDisplaySmall()
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            Text(finished && !(s.error ?? "").isEmpty ? "Finished with a problem: \(s.error!)"
                 : finished ? "Everything is organized. Enjoy the show."
                 : "This only takes a while the first time. You can start browsing whenever you like.")
                .vBodyLarge(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 24)
            HStack(spacing: 12) {
                statTile("\(s.filesFound)", "Videos found")
                statTile(s.toMatch > 0 ? "\(s.matched) / \(s.toMatch)" : "\(s.matched)", "Matched")
            }
            if s.running {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.phase.hasPrefix("Matching") ? "Matching titles with TMDB…" : "Reading your Drive…").vBodyMedium(Theme.textMuted)
                    VProgressBar(min(1, max(0.05, s.toMatch > 0 ? Double(s.matched) / Double(s.toMatch) : 0.05)), height: 4)
                        .animation(.easeInOut(duration: 0.6), value: s.matched)
                }
                .padding(.top, 18)
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).vHeadlineMedium().contentTransition(.numericText()).animation(.easeInOut(duration: 0.6), value: value)
            Text(label).vBodySmall(Theme.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .vHairline(16)
    }
}

/// Eyebrow (uppercased labelSmall Amber), title (displaySmall), body (bodyLarge muted); staggered entrance.
private struct StepHeader: View {
    let eyebrow: String
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow.uppercased()).vLabelSmall(Theme.amber).lineLimit(1).vEntrance(1)
            Text(title).vDisplaySmall().fixedSize(horizontal: false, vertical: true).padding(.top, 8).vEntrance(2)
            Text(text).vBodyLarge(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 24).vEntrance(3)
        }
    }
}

/// TopProgress: optional Back, 4 bars (bar i filled when i < index, the newest animates), "{i} of 4".
private struct TopProgress: View {
    let index: Int
    let canGoBack: Bool
    let onBack: () -> Void
    @State private var filled: Int = 0

    var body: some View {
        HStack(spacing: 14) {
            if canGoBack { VIconButton("chevron.left", help: "Back", size: 38, action: onBack) }
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.outline)
                            RoundedRectangle(cornerRadius: 2).fill(Theme.amber).frame(width: i < filled ? g.size.width : 0)
                        }
                    }
                    .frame(height: 4)
                }
            }
            Text("\(index) of 4").vLabelMedium(Theme.textMuted).fixedSize()
        }
        .frame(height: 38)
        .onAppear {
            filled = max(0, index - 1)
            withAnimation(.easeInOut(duration: 0.6)) { filled = index }
        }
    }
}

/// Scales a fixed-size drawing to fit `box` (never wider than `maxWidth`).
private struct Fitted<Content: View>: View {
    let natural: CGSize
    let box: CGSize
    let maxWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let s = max(0.2, min(min(box.width, maxWidth) / natural.width, box.height / natural.height))
        content
            .frame(width: natural.width, height: natural.height)
            .scaleEffect(s)
            .frame(width: natural.width * s, height: natural.height * s)
    }
}
