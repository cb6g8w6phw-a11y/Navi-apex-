import AVFoundation
import Speech
import SwiftUI

/** Search by voice: listens until you stop talking, then hands back the words. */
@MainActor
final class VoiceSearch: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var heard = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var onDone: ((String) -> Void)?

    func start(onDone: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard !listening else { stop(); return }
        self.onDone = onDone
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { onError("Allow speech recognition in Settings to search by voice."); return }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    Task { @MainActor in
                        guard ok else { onError("Allow the microphone in Settings to search by voice."); return }
                        self.begin(onError: onError)
                    }
                }
            }
        }
    }

    private func begin(onError: (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            onError("Voice search isn't available right now.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
        } catch {
            onError("Couldn't start the microphone.")
            stop()
            return
        }
        heard = ""
        listening = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        task = recognizer.recognitionTask(with: request!) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.listening else { return }
                if let r = result {
                    self.heard = r.bestTranscription.formattedString
                    if r.isFinal { self.finish(); return }
                    self.armSilence()
                }
                if error != nil { self.finish() }
            }
        }
        armSilence(after: 6)
    }

    /** About a second and a half without new words ends it. */
    private func armSilence(after seconds: Double = 1.5) {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        let text = heard.trimmingCharacters(in: .whitespaces)
        let done = onDone
        stop()
        if !text.isEmpty { done?(text) }
    }

    func stop() {
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onDone = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/** The "Listening…" card over the map while voice search runs. */
struct ListeningCard: View {
    @ObservedObject var voice: VoiceSearch
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Vela.routeBlue.opacity(0.25)).frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.15 : 0.9)
                Circle().fill(Vela.routeBlue).frame(width: 60, height: 60)
                Image(systemName: "mic.fill").font(.system(size: 26, weight: .semibold)).foregroundColor(.white)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
            Text(voice.heard.isEmpty ? "Listening…" : voice.heard)
                .font(.title3.weight(.medium)).multilineTextAlignment(.center)
            Button("Cancel") { voice.stop() }.font(.subheadline.weight(.semibold))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
    }
}
