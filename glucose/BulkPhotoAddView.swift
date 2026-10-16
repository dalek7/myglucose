import Photos
import SwiftUI

/// 혈당 기록이 있는 기간(최근 60일)의 사진을 한 번에 보여주고,
/// 고른 사진을 촬영 시각에서 가장 가까운 혈당 측정점에 메모로 연결한다.
/// 한 측정점에 여러 장이 연결될 수 있다.
struct BulkPhotoAddView: View {
    let healthStore: HealthStore
    let photoStore: PhotoNoteStore

    /// 사진 한 장과 그 사진이 연결될 측정점.
    private struct Candidate: Identifiable {
        let assetIdentifier: String
        let creationDate: Date
        /// 촬영 시각에서 가장 가까운 혈당 측정 시각
        let pointDate: Date
        var alreadyAdded: Bool
        var id: String { assetIdentifier }
    }

    private enum LoadState {
        case loading
        case photoAccessDenied
        case healthError(String)
        case noGlucose
        case ready
    }

    @State private var state: LoadState = .loading
    @State private var candidates: [Candidate] = []
    @State private var selected: Set<String> = []
    @State private var limitedAccess = false
    @State private var addedCount: Int?

    /// 사진과 측정점을 연결해 주는 최대 시간 차.
    private static let matchWindow: TimeInterval = 3600
    /// 혈당을 찾아보는 기간. 앱 타임라인이 보여주는 범위(최근 60일)와 같다.
    private static let lookbackDays = 60

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("혈당 기록과 사진을 찾는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .photoAccessDenied:
                ContentUnavailableView {
                    Label("사진 접근 권한 없음", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("설정에서 사진 접근을 허용해야 혈당 기록 기간의 사진을 불러올 수 있습니다.")
                } actions: {
                    Button("설정 열기") { openSettings() }
                }

            case .healthError(let message):
                ContentUnavailableView(
                    "건강 데이터를 읽을 수 없음",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message))

            case .noGlucose:
                ContentUnavailableView(
                    "혈당 기록 없음",
                    systemImage: "drop",
                    description: Text("최근 \(Self.lookbackDays)일에 혈당 기록이 없어 연결할 사진을 찾지 못했습니다."))

            case .ready:
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "연결할 사진 없음",
                        systemImage: "photo",
                        description: Text("혈당 측정 시각 전후 1시간에 찍은 사진이 없습니다."))
                } else {
                    photoGrid
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("음식 사진 일괄 추가")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if case .ready = state, !candidates.isEmpty {
                addBar
            }
        }
        .task {
            await load()
        }
        .alert("추가 완료", isPresented: .init(
            get: { addedCount != nil },
            set: { if !$0 { addedCount = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("사진 \(addedCount ?? 0)장을 가까운 혈당 측정점에 연결했습니다.\n타임라인의 각 날짜에서 확인할 수 있습니다.")
        }
    }

    // MARK: - 그리드

    /// 날짜별 섹션 (최근 날짜가 위).
    private var sections: [(day: Date, items: [Candidate])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: candidates) { calendar.startOfDay(for: $0.creationDate) }
        return grouped
            .map { (day: $0.key, items: $0.value.sorted { $0.creationDate < $1.creationDate }) }
            .sorted { $0.day > $1.day }
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: .sectionHeaders) {
                if limitedAccess {
                    Text("일부 사진만 접근이 허용되어 있습니다. 전체 사진에서 찾으려면 설정에서 모든 사진 접근을 허용하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                ForEach(sections, id: \.day) { section in
                    Section {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                            spacing: 4
                        ) {
                            ForEach(section.items) { candidate in
                                candidateCell(candidate)
                            }
                        }
                        .padding(.horizontal)
                    } header: {
                        Text(Self.dayLabel(section.day))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func candidateCell(_ candidate: Candidate) -> some View {
        let isSelected = selected.contains(candidate.assetIdentifier)
        return Button {
            if isSelected {
                selected.remove(candidate.assetIdentifier)
            } else {
                selected.insert(candidate.assetIdentifier)
            }
        } label: {
            PhotoAssetImage(assetIdentifier: candidate.assetIdentifier)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(Self.timeLabel(candidate.creationDate))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: .capsule)
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                .overlay {
                    if candidate.alreadyAdded {
                        ZStack {
                            Color.black.opacity(0.45)
                            Text("추가됨")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .clipShape(.rect(cornerRadius: 8))
                    } else if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(candidate.alreadyAdded)
        .accessibilityLabel("사진")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var addBar: some View {
        HStack {
            Text(selected.isEmpty ? "사진을 선택하세요" : "\(selected.count)장 선택됨")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                addSelected()
            } label: {
                Text("추가")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - 데이터 로드

    private func load() async {
        // 1. 혈당 읽기 권한
        do {
            try await healthStore.requestAuthorization()
        } catch {
            state = .healthError(error.localizedDescription)
            return
        }

        // 2. 사진 접근 권한 (전체 사진에서 찾으므로 전체 허용이 가장 좋다)
        var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if photoStatus == .notDetermined {
            photoStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard photoStatus == .authorized || photoStatus == .limited else {
            state = .photoAccessDenied
            return
        }
        limitedAccess = photoStatus == .limited

        // 3. 최근 60일 혈당 기록
        let now = Date()
        let start = Calendar.current.startOfDay(
            for: now.addingTimeInterval(-TimeInterval(Self.lookbackDays - 1) * 86400))
        let points: [GlucosePoint]
        do {
            points = try await healthStore.glucose(in: DateInterval(start: start, end: now))
        } catch {
            state = .healthError(error.localizedDescription)
            return
        }
        guard let first = points.first, let last = points.last else {
            state = .noGlucose
            return
        }

        // 4. 기록 구간(±1시간 여유)의 사진을 모아 가장 가까운 측정점에 연결한다
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            first.date.addingTimeInterval(-Self.matchWindow) as NSDate,
            last.date.addingTimeInterval(Self.matchWindow) as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        let pointDates = points.map(\.date)
        let used = photoStore.usedAssetIdentifiers
        var found: [Candidate] = []
        result.enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate,
                  let nearest = Self.nearestDate(to: created, in: pointDates),
                  abs(nearest.timeIntervalSince(created)) <= Self.matchWindow
            else { return }
            found.append(Candidate(
                assetIdentifier: asset.localIdentifier,
                creationDate: created,
                pointDate: nearest,
                alreadyAdded: used.contains(asset.localIdentifier)))
        }
        candidates = found
        state = .ready
    }

    /// 오름차순 정렬된 측정 시각에서 이분 탐색으로 가장 가까운 시각을 찾는다.
    /// CGM이면 60일에 수천 건이라 사진마다 전수 비교하지 않는다.
    private static func nearestDate(to target: Date, in sorted: [Date]) -> Date? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target { low = mid + 1 } else { high = mid }
        }
        // low는 target 이상인 첫 위치. 양옆 중 가까운 쪽을 고른다.
        let after = low < sorted.count ? sorted[low] : nil
        let before = low > 0 ? sorted[low - 1] : nil
        switch (before, after) {
        case (let b?, let a?):
            return abs(b.timeIntervalSince(target)) <= abs(a.timeIntervalSince(target)) ? b : a
        case (let b?, nil): return b
        case (nil, let a?): return a
        case (nil, nil): return nil
        }
    }

    // MARK: - 추가

    private func addSelected() {
        let newNotes = candidates
            .filter { selected.contains($0.assetIdentifier) && !$0.alreadyAdded }
            .map { PhotoNote(pointDate: $0.pointDate, assetIdentifier: $0.assetIdentifier, memo: "") }
        photoStore.add(contentsOf: newNotes)
        for index in candidates.indices where selected.contains(candidates[index].assetIdentifier) {
            candidates[index].alreadyAdded = true
        }
        addedCount = newNotes.count
        selected = []
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 표시

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: date)
    }
}
