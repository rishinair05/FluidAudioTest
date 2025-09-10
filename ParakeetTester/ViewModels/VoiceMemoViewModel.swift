import Foundation
import AVFoundation
import SwiftUI

class VoiceMemoViewModel: ObservableObject {
    @Published var voiceMemos: [VoiceMemo] = []
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentMemo: VoiceMemo?
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingSession: AVAudioSession
    
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
        // Placeholder for transcription logic
        if let index = voiceMemos.firstIndex(where: { $0.id == memo.id }) {
            voiceMemos[index].transcript = "This is a placeholder transcript."
            saveMemos()
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
}