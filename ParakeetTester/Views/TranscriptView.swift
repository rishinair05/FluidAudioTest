
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
                Text(viewModel.voiceMemos.first(where: { $0.id == memo.id })?.transcript ?? memo.transcript ?? "No transcript available.")
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
}
