import CloudKit
import Foundation

/// 식사 메모를 사용자의 iCloud(CloudKit 비공개 DB)로 동기화한다.
///
/// - 커스텀 존 하나("PhotoNotes")에 메모당 레코드 하나를 둔다.
/// - 내려받기: 존 변경 토큰으로 바뀐 것/지워진 것만 받는다. 삭제 전파도 여기서 처리된다.
/// - 올리기: 아직 안 올라간 메모(dirtyIDs)와 안 지워진 삭제(pendingDeleteIDs)를 보낸다.
/// - 충돌: 레코드 전체를 덮어쓰는 last-writer-wins로 올리고,
///   내려받을 때 수정 시각(modifiedAt)이 더 최신인 쪽을 남긴다.
/// - iCloud 미로그인 등으로 실패하면 로컬 저장만으로 동작하고 다음 기회에 다시 시도한다.
extension PhotoNoteStore {
    private static let zoneID = CKRecordZone.ID(zoneName: "PhotoNotes")
    private static let recordType = "PhotoNote"

    /// 화면이 보일 때, 그리고 메모가 바뀔 때마다 호출된다. 중복 호출은 한 번으로 합쳐진다.
    func scheduleSync() {
        Task { @MainActor in
            await syncNow()
        }
    }

    @MainActor
    func syncNow() async {
        if syncInFlight {
            needsAnotherSync = true
            return
        }
        syncInFlight = true
        defer {
            syncInFlight = false
            if needsAnotherSync {
                needsAnotherSync = false
                scheduleSync()
            }
        }

        let container = CKContainer.default()
        do {
            guard try await container.accountStatus() == .available else {
                syncStatusMessage = "iCloud에 로그인되어 있지 않아 이 기기에만 저장됩니다."
                return
            }
            let database = container.privateCloudDatabase
            // 첫 동기화면 존부터 만든다.
            if serverChangeTokenData == nil {
                try await ensureZone(in: database)
            }
            try await pullChanges(from: database)
            try await pushChanges(to: database)
            syncStatusMessage = nil
            markSynced(at: .now)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // iCloud 데이터가 초기화됐으면 처음부터 다시 올린다.
            serverChangeTokenData = nil
            dirtyIDs.formUnion(notes.map(\.id))
            save()
            needsAnotherSync = true
        } catch {
            syncStatusMessage = "동기화 실패: \(error.localizedDescription)"
            save()
        }
    }

    // MARK: - 단계별 구현

    private func ensureZone(in database: CKDatabase) async throws {
        _ = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
    }

    @MainActor
    private func pullChanges(from database: CKDatabase) async throws {
        var moreComing = true
        while moreComing {
            let token = serverChangeTokenData.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
            }
            let changes = try await database.recordZoneChanges(
                inZoneWith: Self.zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case .success(let modification) = result,
                   let note = Self.note(from: modification.record) {
                    applyRemote(note)
                }
            }
            for deletion in changes.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    applyRemoteDeletion(id: id)
                }
            }
            serverChangeTokenData = try? NSKeyedArchiver.archivedData(
                withRootObject: changes.changeToken, requiringSecureCoding: true)
            moreComing = changes.moreComing
        }
    }

    @MainActor
    private func pushChanges(to database: CKDatabase) async throws {
        let toSave = notes.filter { dirtyIDs.contains($0.id) }.map(Self.record(for:))
        let toDelete = pendingDeleteIDs.map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: Self.zoneID)
        }
        guard !toSave.isEmpty || !toDelete.isEmpty else { return }

        let result = try await database.modifyRecords(
            saving: toSave, deleting: toDelete, savePolicy: .allKeys, atomically: false)

        for (recordID, saveResult) in result.saveResults {
            guard let id = UUID(uuidString: recordID.recordName) else { continue }
            if case .success = saveResult {
                dirtyIDs.remove(id)
            }
            // 실패한 것은 dirty로 남겨 다음 동기화 때 다시 올린다.
        }
        for (recordID, deleteResult) in result.deleteResults {
            guard let id = UUID(uuidString: recordID.recordName) else { continue }
            switch deleteResult {
            case .success:
                pendingDeleteIDs.remove(id)
            case .failure(let error as CKError) where error.code == .unknownItem:
                // 서버에 애초에 없던 것도 지운 것으로 친다.
                pendingDeleteIDs.remove(id)
            case .failure:
                break
            }
        }
    }

    // MARK: - 레코드 변환

    private static func record(for note: PhotoNote) -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: note.id.uuidString, zoneID: zoneID))
        record["pointDate"] = note.pointDate
        record["assetIdentifier"] = note.assetIdentifier
        record["assetCloudIdentifier"] = note.assetCloudIdentifier
        record["memo"] = note.memo
        record["carbsGrams"] = note.carbsGrams
        record["healthSampleID"] = note.healthSampleID?.uuidString
        record["createdAt"] = note.createdAt
        record["modifiedAt"] = note.modifiedAt
        return record
    }

    private static func note(from record: CKRecord) -> PhotoNote? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let pointDate = record["pointDate"] as? Date,
              let memo = record["memo"] as? String,
              let createdAt = record["createdAt"] as? Date
        else { return nil }
        return PhotoNote(
            id: id,
            pointDate: pointDate,
            assetIdentifier: record["assetIdentifier"] as? String,
            assetCloudIdentifier: record["assetCloudIdentifier"] as? String,
            memo: memo,
            carbsGrams: record["carbsGrams"] as? Double,
            healthSampleID: (record["healthSampleID"] as? String).flatMap(UUID.init(uuidString:)),
            createdAt: createdAt,
            modifiedAt: record["modifiedAt"] as? Date ?? createdAt)
    }
}
