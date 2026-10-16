import Foundation
import Observation

/// 혈당 측정 시점에 붙인 식사 사진·메모.
/// 사진 원본은 사진 보관함에 그대로 두고 자산 식별자만 기억한다.
struct PhotoNote: Identifiable, Codable {
    let id: UUID
    /// 메모를 붙인 혈당 측정 시각
    let pointDate: Date
    /// 사진 보관함 자산 식별자 (이 기기 기준). 찍어 둔 사진이 없으면 메모만 저장할 수 있다.
    let assetIdentifier: String?
    /// 기기 간 공통 사진 식별자 (iCloud 사진). 다른 기기에서 같은 원본을 찾을 때 쓴다.
    let assetCloudIdentifier: String?
    var memo: String
    /// 입력한 탄수화물 섭취량(g). 입력하면 건강 앱에도 기록한다.
    var carbsGrams: Double?
    /// 건강 앱에 기록된 탄수화물 샘플의 UUID. 메모를 지울 때 함께 지운다.
    var healthSampleID: UUID?
    let createdAt: Date
    /// 마지막 수정 시각. 기기 간 동기화 충돌 시 더 최신 수정이 이긴다.
    var modifiedAt: Date

    init(
        pointDate: Date, assetIdentifier: String?, assetCloudIdentifier: String? = nil,
        memo: String, carbsGrams: Double? = nil
    ) {
        self.id = UUID()
        self.pointDate = pointDate
        self.assetIdentifier = assetIdentifier
        self.assetCloudIdentifier = assetCloudIdentifier
        self.memo = memo
        self.carbsGrams = carbsGrams
        self.createdAt = .now
        self.modifiedAt = .now
    }

    /// 동기화로 받은 레코드를 조립할 때 쓴다.
    init(
        id: UUID, pointDate: Date, assetIdentifier: String?, assetCloudIdentifier: String?,
        memo: String, carbsGrams: Double?, healthSampleID: UUID?, createdAt: Date, modifiedAt: Date
    ) {
        self.id = id
        self.pointDate = pointDate
        self.assetIdentifier = assetIdentifier
        self.assetCloudIdentifier = assetCloudIdentifier
        self.memo = memo
        self.carbsGrams = carbsGrams
        self.healthSampleID = healthSampleID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// 예전 저장 파일에는 수정 시각과 클라우드 식별자가 없으므로 기본값으로 채운다.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pointDate = try container.decode(Date.self, forKey: .pointDate)
        assetIdentifier = try container.decodeIfPresent(String.self, forKey: .assetIdentifier)
        assetCloudIdentifier = try container.decodeIfPresent(
            String.self, forKey: .assetCloudIdentifier)
        memo = try container.decode(String.self, forKey: .memo)
        carbsGrams = try container.decodeIfPresent(Double.self, forKey: .carbsGrams)
        healthSampleID = try container.decodeIfPresent(UUID.self, forKey: .healthSampleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }

    /// 45.0 → "45", 45.5 → "45.5"
    static func gramsText(_ grams: Double) -> String {
        grams.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(grams)) : String(format: "%.1f", grams)
    }
}

/// 사진 메모 저장소. 앱을 다시 켜도 유지되도록 파일에 저장하고,
/// 사용자의 iCloud(CloudKit 비공개 DB)로 기기 간 동기화한다. 동기화 로직은 PhotoNoteSync.swift.
@Observable
final class PhotoNoteStore {
    private(set) var notes: [PhotoNote]

    // MARK: - 동기화 상태 (PhotoNoteSync.swift에서 사용)

    /// 아직 iCloud에 올리지 못한 메모 id.
    var dirtyIDs: Set<UUID>
    /// 아직 iCloud에서 지우지 못한 메모 id.
    var pendingDeleteIDs: Set<UUID>
    /// CloudKit 존 변경 토큰 (아카이브된 형태).
    var serverChangeTokenData: Data?
    private(set) var lastSyncDate: Date?
    /// 동기화가 안 되는 이유를 설정 화면에 보여주기 위한 문구. nil이면 정상.
    var syncStatusMessage: String?
    var syncInFlight = false
    var needsAnotherSync = false

    init() {
        let persisted = Self.load()
        notes = persisted.notes
        dirtyIDs = persisted.dirtyIDs
        pendingDeleteIDs = persisted.pendingDeleteIDs
        serverChangeTokenData = persisted.serverChangeTokenData
        lastSyncDate = persisted.lastSyncDate
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
        dirtyIDs.insert(note.id)
        save()
        scheduleSync()
    }

    /// 일괄 추가. 파일 저장은 한 번만 한다.
    func add(contentsOf newNotes: [PhotoNote]) {
        guard !newNotes.isEmpty else { return }
        notes.append(contentsOf: newNotes)
        dirtyIDs.formUnion(newNotes.map(\.id))
        save()
        scheduleSync()
    }

    func remove(_ note: PhotoNote) {
        notes.removeAll { $0.id == note.id }
        dirtyIDs.remove(note.id)
        pendingDeleteIDs.insert(note.id)
        save()
        scheduleSync()
    }

    /// 메모 내용(메모·탄수화물)을 바꾼다.
    func update(_ note: PhotoNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.modifiedAt = .now
        notes[index] = updated
        dirtyIDs.insert(note.id)
        save()
        scheduleSync()
    }

    /// 건강 앱 기록이 끝난 뒤 샘플 UUID를 메모에 연결해 두거나(nil이면) 연결을 푼다.
    func setHealthSample(_ sampleID: UUID?, for noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].healthSampleID = sampleID
        notes[index].modifiedAt = .now
        dirtyIDs.insert(noteID)
        save()
        scheduleSync()
    }

    /// 이미 메모에 쓰인 사진 자산 식별자 집합 (일괄 추가에서 중복을 거르는 용도).
    var usedAssetIdentifiers: Set<String> {
        Set(notes.compactMap(\.assetIdentifier))
    }

    // MARK: - 설정 화면 표시용 집계

    /// 사진이 붙은 메모 수.
    var photoNoteCount: Int {
        notes.count { $0.assetIdentifier != nil }
    }

    /// iCloud 업로드까지 끝난 사진 메모 수. 동기화가 서버 미러를 유지하므로
    /// "업로드 대기(dirty)가 아닌 것"을 세면 서버에 있는 개수와 같다.
    var uploadedPhotoCount: Int {
        notes.count { $0.assetIdentifier != nil && !dirtyIDs.contains($0.id) }
    }

    // MARK: - 동기화에서 쓰는 내부 반영 (파일 저장은 동기화가 끝날 때 한 번에)

    /// iCloud에서 받은 메모를 반영한다. 로컬에 더 최신 수정이 있으면 로컬을 지킨다.
    func applyRemote(_ remote: PhotoNote) {
        guard !pendingDeleteIDs.contains(remote.id) else { return }
        if let index = notes.firstIndex(where: { $0.id == remote.id }) {
            if dirtyIDs.contains(remote.id), notes[index].modifiedAt >= remote.modifiedAt {
                return
            }
            notes[index] = remote
        } else {
            notes.append(remote)
        }
        dirtyIDs.remove(remote.id)
    }

    /// 다른 기기에서 지운 메모를 반영한다.
    /// 건강 앱 기록은 지운 기기가 이미 처리했으므로 여기서는 건드리지 않는다.
    func applyRemoteDeletion(id: UUID) {
        notes.removeAll { $0.id == id }
        dirtyIDs.remove(id)
    }

    func markSynced(at date: Date) {
        lastSyncDate = date
        save()
    }

    // MARK: - 파일 저장

    private struct Persisted: Codable {
        var notes: [PhotoNote] = []
        var dirtyIDs: Set<UUID> = []
        var pendingDeleteIDs: Set<UUID> = []
        var serverChangeTokenData: Data?
        var lastSyncDate: Date?
    }

    private static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "photo-notes.json")
    }

    private static func load(from url: URL = defaultURL) -> Persisted {
        guard let data = try? Data(contentsOf: url) else { return Persisted() }
        if let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            return persisted
        }
        // 예전 형식([PhotoNote] 배열)이면 전부 아직 안 올라간 것으로 보고 업로드 대상으로 삼는다.
        if let legacy = try? JSONDecoder().decode([PhotoNote].self, from: data) {
            return Persisted(notes: legacy, dirtyIDs: Set(legacy.map(\.id)))
        }
        return Persisted()
    }

    func save(to url: URL = PhotoNoteStore.defaultURL) {
        let persisted = Persisted(
            notes: notes,
            dirtyIDs: dirtyIDs,
            pendingDeleteIDs: pendingDeleteIDs,
            serverChangeTokenData: serverChangeTokenData,
            lastSyncDate: lastSyncDate)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 식사 기록도 건강 데이터에 준해서 기기가 잠겨 있을 때는 읽을 수 없게 저장한다.
            try JSONEncoder().encode(persisted).write(
                to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("photo note save failed: \(error)")
        }
    }
}
