import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = VoiceMemoViewModel()
    @State private var isImporting = false
    @State private var showNameAlert = false
    @State private var showImportNameAlert = false
    @State private var newMemoTitle = ""
    @State private var memoToRename: VoiceMemo? = nil
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(viewModel.voiceMemos) { memo in
                        NavigationLink(destination: PlaybackView(viewModel: viewModel, memo: memo)) {
                            VStack(alignment: .leading) {
                                Text(memo.title)
                                    .font(.headline)
                                Text(memo.date, style: .date)
                                    .font(.caption)
                            }
                        }
                        .contextMenu {
                            Button("Rename") {
                                memoToRename = memo
                                newMemoTitle = memo.title
                                showNameAlert = true
                            }
                        }
                    }
                    .onDelete(perform: viewModel.deleteMemo)
                }
                
                HStack {
                    Button(action: { isImporting = true }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.largeTitle)
                    }
                    .fileImporter(
                        isPresented: $isImporting,
                        allowedContentTypes: [UTType.audio],
                        allowsMultipleSelection: false
                    ) { result in
                        do {
                            let url = try result.get().first! // Force unwrap for simplicity
                            viewModel.importAudio(url: url)
                            newMemoTitle = url.lastPathComponent
                            showImportNameAlert = true
                        } catch {
                            print("Error importing file: \(error)")
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                            newMemoTitle = "New Memo \(viewModel.voiceMemos.count + 1)"
                            showNameAlert = true
                        } else {
                            viewModel.startRecording()
                        }
                    }) {
                        Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(viewModel.isRecording ? .red : .accentColor)
                    }
                }
                .padding()
            }
            .navigationTitle("Voice Memos")
            .onAppear {
                viewModel.requestMicrophonePermission()
            }
            .alert("Name your memo", isPresented: $showNameAlert) {
                TextField("Enter name", text: $newMemoTitle)
                Button("Save") {
                    if let memo = memoToRename {
                        viewModel.renameMemo(memo: memo, newTitle: newMemoTitle)
                    } else if let lastMemo = viewModel.voiceMemos.last {
                        viewModel.renameMemo(memo: lastMemo, newTitle: newMemoTitle)
                    }
                    newMemoTitle = ""
                    memoToRename = nil
                }
            }
            .alert("Name your imported memo", isPresented: $showImportNameAlert) {
                TextField("Enter name", text: $newMemoTitle)
                Button("Save") {
                    if let lastMemo = viewModel.voiceMemos.last {
                        viewModel.renameMemo(memo: lastMemo, newTitle: newMemoTitle)
                    }
                    newMemoTitle = ""
                }
            }
        }
    }
}

extension VoiceMemoViewModel {
    func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if !granted {
                // Handle denied permission
            }
        }
    }
}