import AVFoundation
import AppKit
import Speech
import SwiftUI
import VeltoretKit
import VeltoretUI

/// The Search mic (Android rememberVoiceInput "Say a title, actor or director", Windows VoiceSearch): one phrase
/// through the Speech framework (on-device when supported), with a small listening dialog showing the live
/// transcript and Cancel. Returns nil when nothing was heard, it was cancelled, or speech isn't available (after
/// telling the user why).
@MainActor
public enum VoiceSearch {
    private static var busy = false

    /// Whether voice search can be offered at all (a recognizer for US English exists and the app declares its use).
    public static var isAvailable: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { return false }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil
    }

    public static func listen() async -> String? {
        if busy { return nil }
        busy = true
        defer { busy = false }

        // Without the usage descriptions macOS would terminate the app on the permission request.
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            unavailable()
            return nil
        }

        switch await speechAuthorization() {
        case .authorized: break
        case .denied, .restricted:
            Toast.show("Veltoret can't use speech recognition. Allow it in System Settings.", actionTitle: "Settings") {
                SystemSettingsLinks.open(SystemSettingsLinks.speech)
            }
            return nil
        default:
            return nil
        }
        guard await microphoneAllowed() else {
            Toast.show("Veltoret can't use the microphone. Allow it in System Settings.", actionTitle: "Settings") {
                SystemSettingsLinks.open(SystemSettingsLinks.microphone)
            }
            return nil
        }
        guard recognizer.isAvailable else {
            unavailable()
            return nil
        }

        let session = ListeningSession(recognizer: recognizer)
        do {
            try session.start()
        } catch {
            Log.error(error, "Starting voice search")
            unavailable()
            return nil
        }
        let result: String? = await Dialogs.present { ctl in ListeningDialog(session: session, controller: ctl) }
        session.stop()
        let text = (result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if result == nil { return nil }            // Cancel / Esc
        if text.isEmpty {
            Toast.show(session.failed ? "Voice search isn't available right now. Try again." : "Didn't catch that. Try again.")
            return nil
        }
        return text
    }

    private static func unavailable() {
        Toast.show("Voice search isn't available on this Mac. Check your microphone and speech settings.",
                   actionTitle: "Settings") {
            SystemSettingsLinks.open(SystemSettingsLinks.speech)
        }
    }

    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// One recognition: microphone → SFSpeechAudioBufferRecognitionRequest, live transcript, ends after a pause.
@MainActor
final class ListeningSession: ObservableObject {
    @Published var transcript = ""
    @Published var finished = false
    private(set) var failed = false

    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var started = Date()

    /// Nothing heard for this long at the start ends the session; after speech, a pause this long does.
    static let initialSilence: TimeInterval = 6
    static let endSilence: TimeInterval = 1.4

    init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    func start() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        started = Date()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in self?.update(text: text, isFinal: isFinal, failed: failed) }
        }
        armTimer(Self.initialSilence)
    }

    private func update(text: String?, isFinal: Bool, failed: Bool) {
        guard !finished else { return }
        if let text { transcript = text }
        if failed { self.failed = transcript.isEmpty }
        if isFinal || failed { finish(); return }
        if text != nil { armTimer(Self.endSilence) }
    }

    private func armTimer(_ seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        stopAudio()
    }

    func stop() {
        finished = true
        stopAudio()
        task?.cancel()
        task = nil
    }

    private func stopAudio() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    enum VoiceError: Error { case noMicrophone }
}

private struct ListeningDialog: View {
    @ObservedObject var session: ListeningSession
    let controller: DialogController<String>
    @State private var pulse = false

    var body: some View {
        VDialog(title: nil, width: 380) {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Theme.amberDim).frame(width: 72, height: 72)
                        .scaleEffect(pulse ? 1.12 : 0.94)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    Image(systemName: "mic.fill").font(.system(size: 28, weight: .medium)).foregroundStyle(Theme.amber)
                }
                .padding(.top, 6)
                Text("Listening…").vTitleMedium()
                Text(session.transcript.isEmpty ? "Say a title, actor or director" : session.transcript)
                    .vBodyMedium(session.transcript.isEmpty ? Theme.textMuted : Theme.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        } actions: {
            Button("Cancel") { session.stop(); controller.dismiss() }
                .buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            Button("Done") { session.finish() }
                .buttonStyle(.vText).keyboardShortcut(.defaultAction)
                .disabled(session.transcript.isEmpty)
        }
        .onAppear { pulse = true }
        .onChange(of: session.finished) { _, done in
            if done { controller.close(session.transcript) }
        }
    }
}
