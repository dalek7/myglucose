import SwiftUI

/// 기간 단위를 고르고, 좌우 스와이프로 기간을 넘겨 보는 타임라인.
struct GlucoseTimelineView: View {
    let healthStore: HealthStore

    @State private var photoStore = PhotoNoteStore()
    @State private var scope: TimeScope = .day
    @State private var pageIndex: Int = TimeScope.day.pageCount - 1

    var body: some View {
        VStack(spacing: 0) {
            Picker("기간", selection: $scope) {
                ForEach(TimeScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            TabView(selection: $pageIndex) {
                ForEach(0..<scope.pageCount, id: \.self) { index in
                    PeriodPageView(
                        healthStore: healthStore,
                        photoStore: photoStore,
                        scope: scope,
                        interval: scope.interval(forPage: index))
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("혈당")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) {
            pageIndex = scope.pageCount - 1
        }
    }
}

#Preview {
    NavigationStack {
        GlucoseTimelineView(healthStore: HealthStore())
    }
}
