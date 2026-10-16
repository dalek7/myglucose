import Foundation
import Observation

/// 혈당 측정 시점에 붙인 식사 사진·메모.
/// 사진 원본은 사진 보관함에 그대로 두고 자산 식별자만 기억한다.
struct PhotoNote: Identifiable, Codable {
    let id: UUID
    /// 메모를 붙인 혈당 측정 시각
    let pointDate: Date
    /// 사진 보관함 자산 식별자. 찍어 둔 사진이 없으면 메모만 저장할 수 있다.
    let assetIdentifier: String?
    var memo: String
    /// 입력한 탄수화물 섭취량(g). 입력하면 건강 앱에도 기록한다.
    var carbsGrams: Double?
    /// 건강 앱에 기록된 탄수화물 샘플의 UUID. 메모를 지울 때 함께 지운다.
    var healthSampleID: UUID?
    let createdAt: Date

    init(pointDate: Date, assetIdentifier: String?, memo: String, carbsGrams: Double? = nil) {
        self.id = UUID()
        self.pointDate = pointDate
        self.assetIdentifier = assetIdentifier
        self.memo = memo
        self.carbsGrams = carbsGrams
        self.createdAt = .now
    }

    /// 45.0 → "45", 45.5 → "45.5"
    static func gramsText(_ grams: Double) -> String {
        grams.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(grams)) : String(format: "%.1f", grams)
    }
}

/// 사진 메모 저장소. 앱을 다시 켜도 유지되도록 파일에 저장한다.
@Observable
final class PhotoNoteStore {
    private(set) var notes: [PhotoNote]

    init() {
        notes = Self.load()
    }

    func notes(in interval: DateInterval) -> [PhotoNote] {
        notes
            .filter { interval.contains($0.pointDate) }
            .sorted { $0.pointDate < $1.pointDate }
    }

    func note(at pointDate: Date) -> PhotoNote? {
        notes.first { $0.pointDate == pointDate }
    }

    func add(_ note: PhotoNote) {
        notes.append(note)
        save()
    }

    func remove(_ note: PhotoNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    /// 메모 내용(메모·탄수화물)을 바꾼다.
    func update(_ note: PhotoNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        save()
    }

    /// 건강 앱 기록이 끝난 뒤 샘플 UUID를 메모에 연결해 두거나(nil이면) 연결을 푼다.
    func setHealthSample(_ sampleID: UUID?, for noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].healthSampleID = sampleID
        save()
    }

    // MARK: - 파일 저장

    private static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "photo-notes.json")
    }

    private static func load(from url: URL = defaultURL) -> [PhotoNote] {
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([PhotoNote].self, from: data)
        else { return [] }
        return notes
    }

    private func save(to url: URL = PhotoNoteStore.defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 식사 기록도 건강 데이터에 준해서 기기가 잠겨 있을 때는 읽을 수 없게 저장한다.
            try JSONEncoder().encode(notes).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("photo note save failed: \(error)")
        }
    }
}
