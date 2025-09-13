import Foundation
import AVFoundation
import SwiftUI
import FluidAudio
import Darwin
import NaturalLanguage
import Speech

class VoiceMemoViewModel: ObservableObject {
    enum TranscriptionEngine: String, CaseIterable, Identifiable {
        case parakeet
        case apple
        var id: String { rawValue }
        var displayName: String { self == .parakeet ? "Parakeet" : "Apple" }
    }

    @Published var voiceMemos: [VoiceMemo] = []
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentMemo: VoiceMemo?
    @Published var isTranscribing = false
    @Published var transcriptionStats: [UUID: TranscriptionStats] = [:]
    @Published var sentenceTimestamps: [UUID: [SentenceTimestamp]] = [:]
    @Published var engine: TranscriptionEngine = .parakeet
    
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

    func seek(to time: TimeInterval, memo: VoiceMemo) {
        if audioPlayer == nil || currentMemo != memo {
            _ = createPlayback(memo: memo)
            currentMemo = memo
        }
        audioPlayer?.currentTime = max(0, time)
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
        isPlaying = true
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
                switch engine {
                case .parakeet:
                    try await self.transcribeWithParakeet(memo: memo)
                case .apple:
                    try await self.transcribeWithSpeechTranscriber(memo: memo)
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

    private func transcribeWithSpeechTranscriber(memo: VoiceMemo) async throws {

        // Metrics
        let (cpuUserBefore, cpuSysBefore) = self.processCPUTimeSeconds()
        let memBefore = self.currentResidentMemoryBytes()
        let start = Date()

        // Configure a general-purpose transcriber; ignore timestamps/attributes for now
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en_US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Start analyzer and feed a single 16-bit PCM buffer of the whole file
        try await analyzer.start(inputSequence: stream)

        let audioFile = try AVAudioFile(forReading: memo.url)
    let srcFormat = audioFile.processingFormat
    let totalFrames = AVAudioFrameCount(audioFile.length)
    let audioDuration: TimeInterval = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -30, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate source buffer for Apple transcription"])
        }
        try audioFile.read(into: srcBuffer)

    // Target: 16-bit signed integer PCM, 16kHz mono interleaved
    guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -31, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format (Int16)"])
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -32, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter (to Int16)"])
        }

        // Estimate destination frames (same sample rate, so same frames)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "VoiceMemoViewModel", code: -33, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate destination buffer (Int16)"])
        }

        var didSupply = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didSupply {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupply = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        var convError: NSError?
        _ = converter.convert(to: dstBuffer, error: &convError, withInputFrom: inputBlock)
        if let convError = convError { throw convError }

        continuation.yield(AnalyzerInput(buffer: dstBuffer))
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()

        // Collect final best result
        var finalAttributed = AttributedString("")
        for try await result in transcriber.results {
            if !finalAttributed.characters.isEmpty { finalAttributed.append(AttributedString(" ")) }
            finalAttributed += result.text
        }
        let text = String(finalAttributed.characters)

        let end = Date()
        let (cpuUserAfter, cpuSysAfter) = self.processCPUTimeSeconds()
        let memAfter = self.currentResidentMemoryBytes()

        let cpuUserDelta = max(0, cpuUserAfter - cpuUserBefore)
        let cpuSysDelta = max(0, cpuSysAfter - cpuSysBefore)
        let cpuTotalDelta = cpuUserDelta + cpuSysDelta
        let processingSeconds = end.timeIntervalSince(start)
    let tokenCount = max(1, text.split{ $0.isWhitespace }.count)
    let tokensPerSecond: Double = processingSeconds > 0 ? Double(tokenCount) / processingSeconds : 0.0
    let rtf: Double = 0.0

        await MainActor.run {
            if let index = self.voiceMemos.firstIndex(where: { $0.id == memo.id }) {
                self.voiceMemos[index].transcript = text
                self.saveMemos()
            }
            // Skip timestamps per request
            self.transcriptionStats[memo.id] = TranscriptionStats(
                modelLoadSeconds: 0,
                initializeSeconds: 0,
                transcriptionSeconds: processingSeconds,
                audioDurationSeconds: audioDuration,
                realTimeFactor: rtf,
                tokenCount: tokenCount,
                tokensPerSecond: tokensPerSecond,
                cpuUserSeconds: cpuUserDelta,
                cpuSystemSeconds: cpuSysDelta,
                cpuTotalSeconds: cpuTotalDelta,
                memoryResidentBeforeBytes: memBefore,
                memoryResidentAfterBytes: memAfter
            )
            self.isTranscribing = false
        }
    }

    // MARK: - Parakeet path factored out
    private func transcribeWithParakeet(memo: VoiceMemo) async throws {
        // Initialize FluidAudio ASR once and reuse; measure model load/initialize time
        var modelLoadSeconds: TimeInterval = 0
        var initializeSeconds: TimeInterval = 0
        if asrManager == nil {
            let loadStart = Date()
            let models = try await AsrModels.downloadAndLoad()
            modelLoadSeconds = Date().timeIntervalSince(loadStart)
            let manager = AsrManager(config: .default)
            let initStart = Date()
            try await manager.initialize(models: models)
            initializeSeconds = Date().timeIntervalSince(initStart)
            asrManager = manager
        }
        guard let asrManager else { throw NSError(domain: "VoiceMemoViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "ASR manager unavailable"]) }

        // Load and convert audio to Float32 mono 16kHz samples using AVAudioConverter
        let samples = try self.loadSamples16kMono(url: memo.url)

        // Transcribe with CPU/memory measurement
        let (cpuUserBefore, cpuSysBefore) = self.processCPUTimeSeconds()
        let memBefore = self.currentResidentMemoryBytes()
        let transStart = Date()
        let result = try await asrManager.transcribe(samples, source: .system)
        let transWallSeconds = Date().timeIntervalSince(transStart)
        let (cpuUserAfter, cpuSysAfter) = self.processCPUTimeSeconds()
        let memAfter = self.currentResidentMemoryBytes()
        let cpuUserDelta = max(0, cpuUserAfter - cpuUserBefore)
        let cpuSysDelta = max(0, cpuSysAfter - cpuSysBefore)
        let cpuTotalDelta = cpuUserDelta + cpuSysDelta

        // Derive token count and throughput
        let tokenCount: Int
        if let timings = result.tokenTimings, !timings.isEmpty {
            tokenCount = timings.count
        } else {
            // Fallback: approximate tokens as words
            tokenCount = result.text.split{ $0.isWhitespace }.count
        }
        let processingSeconds = result.processingTime > 0 ? result.processingTime : transWallSeconds
        let tokensPerSecond = processingSeconds > 0 ? Double(tokenCount) / processingSeconds : 0
        let rtf = processingSeconds > 0 ? (result.duration / processingSeconds) : 0

        await MainActor.run {
            if let index = self.voiceMemos.firstIndex(where: { $0.id == memo.id }) {
                self.voiceMemos[index].transcript = result.text
                self.saveMemos()
            }
            // Compute sentence-level timestamps if token timings are available
            if let timings = result.tokenTimings, !timings.isEmpty {
                self.sentenceTimestamps[memo.id] = self.computeSentenceTimestamps(
                    text: result.text,
                    tokenTimings: timings,
                    audioDuration: result.duration
                )
            }
            // Save stats for display
            self.transcriptionStats[memo.id] = TranscriptionStats(
                modelLoadSeconds: modelLoadSeconds,
                initializeSeconds: initializeSeconds,
                transcriptionSeconds: processingSeconds,
                audioDurationSeconds: result.duration,
                realTimeFactor: rtf,
                tokenCount: tokenCount,
                tokensPerSecond: tokensPerSecond,
                cpuUserSeconds: cpuUserDelta,
                cpuSystemSeconds: cpuSysDelta,
                cpuTotalSeconds: cpuTotalDelta,
                memoryResidentBeforeBytes: memBefore,
                memoryResidentAfterBytes: memAfter
            )
            self.isTranscribing = false
        }
    }

    // Stats model to render in UI
    struct TranscriptionStats {
        let modelLoadSeconds: TimeInterval
        let initializeSeconds: TimeInterval
        let transcriptionSeconds: TimeInterval
        let audioDurationSeconds: TimeInterval
        let realTimeFactor: Double
        let tokenCount: Int
        let tokensPerSecond: Double
        let cpuUserSeconds: TimeInterval
        let cpuSystemSeconds: TimeInterval
        let cpuTotalSeconds: TimeInterval
        let memoryResidentBeforeBytes: UInt64
        let memoryResidentAfterBytes: UInt64
    }

    // MARK: - Sentence timestamps from token timings
    struct SentenceTimestamp: Identifiable {
        let id = UUID()
        let sentence: String
        let startTime: TimeInterval
    }

    private func computeSentenceTimestamps(
        text: String,
        tokenTimings: [TokenTiming],
        audioDuration: TimeInterval
    ) -> [SentenceTimestamp] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Sentence ranges
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentenceRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            sentenceRanges.append(range)
            return true
        }

        // Align tokens to text indices (skip whitespace in text)
        // tokenTimings tokens are subword pieces without ▁; we match characters ignoring spaces
        var tokenStartIndices: [Int] = Array(repeating: 0, count: tokenTimings.count)
        let textChars = Array(trimmed)
        var textIdx = 0
        for (i, tok) in tokenTimings.enumerated() {
            let tokenChars = Array(tok.token)
            var tokenStartedAt = -1

            var j = 0
            while j < tokenChars.count && textIdx < textChars.count {
                // Skip whitespace in text
                while textIdx < textChars.count && textChars[textIdx].isWhitespace { textIdx += 1 }
                if textIdx >= textChars.count { break }
                let cText = textChars[textIdx].lowercased()
                let cTok = String(tokenChars[j]).lowercased()
                if cText == cTok {
                    if tokenStartedAt == -1 {
                        tokenStartedAt = textIdx
                    }
                    textIdx += 1
                    j += 1
                } else {
                    // If mismatch (punctuation or normalization), advance text index
                    textIdx += 1
                }
            }
            tokenStartIndices[i] = max(0, tokenStartedAt)
        }

        // Build sentence timestamps using first token that falls within the sentence
        var results: [SentenceTimestamp] = []
        for range in sentenceRanges {
            let startOffset = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
            let endOffset = trimmed.distance(from: trimmed.startIndex, to: range.upperBound)
            // Find first token whose mapped start lies within this sentence
            var startTime: TimeInterval? = nil
            for (idx, start) in tokenStartIndices.enumerated() {
                if start >= startOffset && start < endOffset {
                    startTime = tokenTimings[idx].startTime
                    break
                }
            }

            let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ts = startTime {
                results.append(SentenceTimestamp(sentence: sentence, startTime: ts))
            } else {
                // Fallback: approximate by proportional position in audio
                let fraction = Double(startOffset) / max(1.0, Double(textChars.count))
                let approx = fraction * audioDuration
                results.append(SentenceTimestamp(sentence: sentence, startTime: approx))
            }
        }

        return results
    }

    // MARK: - Resource measurement helpers
    private func processCPUTimeSeconds() -> (user: TimeInterval, system: TimeInterval) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let sys = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return (user, sys)
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return UInt64(info.resident_size)
        } else {
            return 0
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