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
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView(healthStore: HealthStore(), photoStore: PhotoNoteStore())
    }
}
