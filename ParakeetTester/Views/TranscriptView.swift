
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var viewModel: VoiceMemoViewModel
    let memo: VoiceMemo

    var body: some View {
        VStack {
            Text("Transcript")
                .font(.largeTitle)
                .padding()
            if viewModel.isTranscribing && (viewModel.voiceMemos.first(where: { $0.id == memo.id })?.transcript == nil) {
                ProgressView("Transcribing…")
                    .padding()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.voiceMemos.first(where: { $0.id == memo.id })?.transcript ?? memo.transcript ?? "No transcript available.")
                    
                    Divider()
                    if let stats = viewModel.transcriptionStats[memo.id] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Stats").font(.headline)
                            statRow("Model load", formatSeconds(stats.modelLoadSeconds))
                            statRow("Model init", formatSeconds(stats.initializeSeconds))
                            statRow("Transcription", formatSeconds(stats.transcriptionSeconds))
                            statRow("Audio duration", formatSeconds(stats.audioDurationSeconds))
                            statRow("RTFx", String(format: "%.2fx", stats.realTimeFactor))
                            statRow("Tokens", String(stats.tokenCount))
                            statRow("Tokens/sec", String(format: "%.2f", stats.tokensPerSecond))
                            statRow("CPU user", formatSeconds(stats.cpuUserSeconds))
                            statRow("CPU system", formatSeconds(stats.cpuSystemSeconds))
                            statRow("CPU total", formatSeconds(stats.cpuTotalSeconds))
                            statRow("Memory before", byteString(stats.memoryResidentBeforeBytes))
                            statRow("Memory after", byteString(stats.memoryResidentAfterBytes))
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            // Trigger transcription if we don't have one yet
            if viewModel.voiceMemos.first(where: { $0.id == memo.id })?.transcript == nil {
                viewModel.transcribe(memo: memo)
            }
        }
    }

    // MARK: - Formatting helpers
    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func formatSeconds(_ t: TimeInterval) -> String {
        if t < 1 {
            return String(format: "%.0f ms", t * 1000)
        } else {
            return String(format: "%.2f s", t)
        }
    }

    private func byteString(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: unitIndex == 0 ? "%.0f %@" : "%.2f %@", value, units[unitIndex])
    }
}
