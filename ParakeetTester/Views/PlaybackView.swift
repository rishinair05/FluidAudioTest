
import SwiftUI
import AVFoundation

struct PlaybackView: View {
    @ObservedObject var viewModel: VoiceMemoViewModel
    let memo: VoiceMemo
    
    @State private var isEditing = false
    @State private var newTitle: String
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var audioPlayer: AVAudioPlayer?
    
    init(viewModel: VoiceMemoViewModel, memo: VoiceMemo) {
        self.viewModel = viewModel
        self.memo = memo
        _newTitle = State(initialValue: memo.title)
    }
    
    var body: some View {
        VStack {
            if isEditing {
                TextField("Enter new title", text: $newTitle, onCommit: {
                    viewModel.renameMemo(memo: memo, newTitle: newTitle)
                    isEditing = false
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
            } else {
                Text(memo.title)
                    .font(.largeTitle)
                    .onTapGesture {
                        isEditing = true
                    }
            }
            
            Text(memo.date, style: .date)
                .font(.caption)
                .foregroundColor(.gray)
            
            Slider(value: $currentTime, in: 0...duration, onEditingChanged: { editing in
                if !editing {
                    audioPlayer?.currentTime = currentTime
                }
            })
            .padding()
            
            HStack {
                Text(timeString(time: currentTime))
                Spacer()
                Text(timeString(time: duration))
            }
            .padding([.leading, .trailing])
            
            HStack(spacing: 40) {
                Button(action: {
                    if viewModel.isPlaying {
                        viewModel.stopPlayback()
                    } else {
                        viewModel.startPlayback(memo: memo)
                    }
                }) {
                    Image(systemName: viewModel.isPlaying && viewModel.currentMemo == memo ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
            }
        }
        .onAppear(perform: setupAudio)
        .onDisappear(perform: {
            viewModel.stopPlayback()
        })
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.isPlaying && viewModel.currentMemo == memo {
                currentTime = audioPlayer?.currentTime ?? 0
            }
        }
    }
    
    private func setupAudio() {
        audioPlayer = viewModel.createPlayback(memo: memo)
        duration = audioPlayer?.duration ?? 0
        viewModel.startPlayback(memo: memo)
    }
    
    private func timeString(time: TimeInterval) -> String {
        let minute = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minute, seconds)
    }
}
