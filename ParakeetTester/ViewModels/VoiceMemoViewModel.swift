import Foundation
import AVFoundation
import SwiftUI
import FluidAudio

class VoiceMemoViewModel: ObservableObject {
    @Published var voiceMemos: [VoiceMemo] = []
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentMemo: VoiceMemo?
    @Published var isTranscribing = false
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingSession: AVAudioSession
    
    // FluidAudio ASR components (lazy-initialized on first transcription)
    private var asrManager: AsrManager?
    
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    init() {
        self.recordingSession = AVAudioSession.sharedInstance()
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default, options: .allowBluetoothA2DP)
            try recordingSession.setActive(true)
        } catch {
            print("Failed to set up recording session: \(error)")
        }
        loadMemos()
    }
    
    func startRecording() {
        let recordingName = "memo-\(Date().timeIntervalSince1970).m4a"
        let recordingURL = documentsDirectory.appendingPathComponent(recordingName)
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            print("Could not start recording: \(error)")
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        
        guard let url = audioRecorder?.url else { return }
        let newMemo = VoiceMemo(id: UUID(), title: "New Memo \(voiceMemos.count + 1)", date: Date(), url: url)
        voiceMemos.append(newMemo)
        saveMemos()
    }
    
    func startPlayback(memo: VoiceMemo) {
        do {
            try recordingSession.setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        if let player = audioPlayer {
            player.play()
        } else {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: memo.url)
                audioPlayer?.play()
            } catch {
                print("Could not create audio player: \(error)")
            }
        }
        isPlaying = true
        currentMemo = memo
    }
    
    func stopPlayback() {
        audioPlayer?.pause()
        isPlaying = false
    }
    
    func createPlayback(memo: VoiceMemo) -> AVAudioPlayer? {
        do {
            try recordingSession.setActive(true)
            let audioPlayer = try AVAudioPlayer(contentsOf: memo.url)
            self.audioPlayer = audioPlayer
            return audioPlayer
        } catch {
            print("Could not create audio player: \(error)")
            return nil
        }
    }
    
    func deleteMemo(at offsets: IndexSet) {
        offsets.forEach { index in
            let memo = voiceMemos[index]
            do {
                try FileManager.default.removeItem(at: memo.url)
            } catch {
                print("Could not delete file: \(error)")
            }
        }
        voiceMemos.remove(atOffsets: offsets)
        saveMemos()
    }
    
    func renameMemo(memo: VoiceMemo, newTitle: String) {
        if let index = voiceMemos.firstIndex(where: { $0.id == memo.id }) {
            voiceMemos[index].title = newTitle
            saveMemos()
        }
    }

    func transcribe(memo: VoiceMemo) {
        // Kick off an async transcription using FluidAudio.
        isTranscribing = true
        Task {
            do {
                // Initialize FluidAudio ASR once and reuse
                if asrManager == nil {
                    let models = try await AsrModels.downloadAndLoad()
                    let manager = AsrManager(config: .default)
                    try await manager.initialize(models: models)
                    asrManager = manager
                }
                guard let asrManager else { throw NSError(domain: "VoiceMemoViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "ASR manager unavailable"]) }

                // Load and convert audio to Float32 mono 16kHz samples using AVAudioConverter
                let samples = try self.loadSamples16kMono(url: memo.url)

                // Transcribe
                let result = try await asrManager.transcribe(samples, source: .system)

                await MainActor.run {
                    if let index = self.voiceMemos.firstIndex(where: { $0.id == memo.id }) {
                        self.voiceMemos[index].transcript = result.text
                        self.saveMemos()
                    }
                    self.isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    if let index = self.voiceMemos.firstIndex(where: { $0.id == memo.id }) {
                        self.voiceMemos[index].transcript = "Transcription failed: \(error.localizedDescription)"
                        self.saveMemos()
                    }
                    self.isTranscribing = false
                }
            }
        }
    }
    
    func importAudio(url: URL) {
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let newName = "imported-\(Date().timeIntervalSince1970).m4a"
        let destinationURL = documentsDirectory.appendingPathComponent(newName)
        
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
            let newMemo = VoiceMemo(id: UUID(), title: "Imported Memo", date: Date(), url: destinationURL)
            voiceMemos.append(newMemo)
            saveMemos()
        } catch {
            print("Could not import audio: \(error)")
        }
    }
    
    private func saveMemos() {
        let memos = voiceMemos.map { [$0.id.uuidString, $0.title, $0.date.timeIntervalSince1970, $0.url.absoluteString, $0.transcript ?? ""] }
        UserDefaults.standard.set(memos, forKey: "voiceMemos")
    }
    
    private func loadMemos() {
        guard let savedMemos = UserDefaults.standard.array(forKey: "voiceMemos") as? [[Any]] else { return }
        
        self.voiceMemos = savedMemos.compactMap { item in
            guard let id = UUID(uuidString: item[0] as? String ?? ""),
                  let title = item[1] as? String,
                  let date = item[2] as? TimeInterval,
                  let urlString = item[3] as? String,
                  let url = URL(string: urlString) else {
                return nil
            }
            let transcript = item.count > 4 ? item[4] as? String : nil
            return VoiceMemo(id: id, title: title, date: Date(timeIntervalSince1970: date), url: url, transcript: transcript)
        }
    }

    // MARK: - Audio Utilities

    /// Load an audio file and convert it to 16kHz mono Float32 samples
    private func loadSamples16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        // Fast path: already 16kHz mono Float32
        if srcFormat.sampleRate == 16000,
           srcFormat.commonFormat == .pcmFormatFloat32,
           srcFormat.channelCount == 1 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
                throw NSError(domain: "VoiceMemoViewModel", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"])
            }
            try file.read(into: buf)
            guard let data = buf.floatChannelData else { return [] }
            let count = Int(buf.frameLength)
            return Array(UnsafeBufferPointer(start: data[0], count: count))
        }

        // Convert to 16kHz mono Float32
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer"])
        }
        try file.read(into: srcBuffer)

        // Estimate destination capacity conservatively
        let estimatedDstFrames = AVAudioFrameCount(Double(totalFrames) * targetFormat.sampleRate / max(1.0, srcFormat.sampleRate) + 1)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedDstFrames) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate destination buffer"])
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        var isConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if isConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            isConsumed = true
            return srcBuffer
        }

        var convError: NSError?
        _ = converter.convert(to: dstBuffer, error: &convError, withInputFrom: inputBlock)
        if let convError = convError { throw convError }

        // Extract mono float samples from destination buffer
        guard let dstData = dstBuffer.floatChannelData else { return [] }
        let outCount = Int(dstBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: dstData[0], count: outCount))
    }
}