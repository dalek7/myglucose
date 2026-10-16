import SwiftUI

/// 첫 화면의 설정 버튼으로 들어오는 설정 목록.
struct SettingsView: View {
    let healthStore: HealthStore
    let photoStore: PhotoNoteStore

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BulkPhotoAddView(healthStore: healthStore, photoStore: photoStore)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("음식 사진 일괄 추가하기")
                            Text("혈당 기록이 있는 기간의 사진을 한 번에 골라 가까운 측정점에 연결합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "photo.stack")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("식사 기록")
            }

            Section {
                LabeledContent("상태") {
                    Text(syncStatusText)
                        .multilineTextAlignment(.trailing)
                }
                NavigationLink {
                    PhotoGalleryView(photoStore: photoStore)
                } label: {
                    LabeledContent("iCloud에 저장된 사진") {
                        Text(uploadedCountText)
                    }
                }
                Button {
                    Task { await photoStore.syncNow() }
                } label: {
                    Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(photoStore.syncInFlight)
            } header: {
                Text("iCloud 동기화")
            } footer: {
                Text("식사 사진·메모는 나의 iCloud로 기기 간 동기화됩니다. 혈당·운동·탄수화물 기록은 iCloud의 건강 동기화가, 사진 원본은 iCloud 사진이 각각 담당합니다.")
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var uploadedCountText: String {
        let uploaded = photoStore.uploadedPhotoCount
        let pending = photoStore.photoNoteCount - uploaded
        return pending > 0 ? "\(uploaded)장 (업로드 대기 \(pending)장)" : "\(uploaded)장"
    }

    private var syncStatusText: String {
        if photoStore.syncInFlight { return "동기화 중…" }
        if let message = photoStore.syncStatusMessage { return message }
        guard let date = photoStore.lastSyncDate else { return "아직 동기화 전" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d a h:mm"
        return "마지막 동기화 \(formatter.string(from: date))"
    }
}

#Preview {
    NavigationStack {
        SettingsView(healthStore: HealthStore(), photoStore: PhotoNoteStore())
    }
}
