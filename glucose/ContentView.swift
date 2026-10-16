import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var healthStore = HealthStore()
    @State private var photoStore = PhotoNoteStore()
    @State private var showTimeline = false
    @State private var showSettings = false
    @State private var requesting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            intro
                .navigationTitle("혈당")
                .navigationDestination(isPresented: $showTimeline) {
                    GlucoseTimelineView(healthStore: healthStore, photoStore: photoStore)
                }
                .navigationDestination(isPresented: $showSettings) {
                    SettingsView(healthStore: healthStore, photoStore: photoStore)
                }
        }
        .tint(.glucose)
        .task {
            await photoStore.syncNow()
        }
        .onChange(of: scenePhase) { _, phase in
            // 다른 기기에서 바꾼 메모를 앱으로 돌아올 때마다 끌어온다.
            if phase == .active {
                photoStore.scheduleSync()
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "drop.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.glucose.gradient)

            Text("혈당 기록")
                .font(.largeTitle.bold())

            Text("Apple 건강 앱에 저장된 혈당 측정치와\n연속혈당(CGM) 기록을 불러와 보여줍니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                startQuery()
            } label: {
                if requesting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    Text("조회")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(requesting)
            .padding(.horizontal, 24)

            Button {
                showSettings = true
            } label: {
                Label("설정", systemImage: "gearshape")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)

            Text("조회 버튼을 누르면 건강 데이터 읽기 권한을 요청합니다.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .alert("조회할 수 없음", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func startQuery() {
        requesting = true
        Task {
            defer { requesting = false }
            do {
#if DEBUG
                await healthStore.seedDemoDataIfRequested()
#endif
                try await healthStore.requestAuthorization()
                showTimeline = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension Color {
    /// 건강 앱 혈당 지표 계열의 포인트 색.
    static let glucose = Color(red: 0.94, green: 0.26, blue: 0.3)
}

#Preview {
    ContentView()
}
