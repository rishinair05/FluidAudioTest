
import Foundation

struct VoiceMemo: Identifiable, Equatable {
    let id: UUID
    var title: String
    let date: Date
    let url: URL
    var transcript: String?
}
