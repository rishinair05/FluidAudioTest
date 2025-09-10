
import SwiftUI

struct TranscriptView: View {
    let memo: VoiceMemo

    var body: some View {
        VStack {
            Text("Transcript")
                .font(.largeTitle)
                .padding()
            ScrollView {
                Text(memo.transcript ?? "No transcript available.")
                    .padding()
            }
        }
    }
}
