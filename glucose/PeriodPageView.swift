import SwiftUI

/// 한 기간(일/주/월)의 혈당 차트·요약과 운동 조회를 담는 페이지.
struct PeriodPageView: View {
    let healthStore: HealthStore
    let photoStore: PhotoNoteStore
    let scope: TimeScope
    let interval: DateInterval

    @State private var points: [GlucosePoint] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var workoutState: WorkoutLoadState = .idle
    /// 목록에서 고른 운동. 차트가 그 구간으로 확대된다.
    @State private var selectedWorkoutID: UUID?
    /// 사진 시트를 띄울 혈당 측정 시각.
    @State private var photoTarget: PhotoTarget?
    /// 크게 보기로 띄울 사진.
    @State private var viewerTarget: ViewerTarget?
    /// 수정 시트를 띄울 메모.
    @State private var editingNote: PhotoNote?
    /// 배지를 탭했을 때 모아 보여줄 메모들.
    @State private var notesSheet: NotesSheetTarget?
    /// 탄수화물을 건강 앱에 기록하지 못했을 때의 안내.
    @State private var carbsSaveError: String?
    /// 차트 밖 화면을 탭할 때마다 올려서 차트의 값 선택을 푼다.
    @State private var deselectSignal = 0

    enum WorkoutLoadState {
        case idle
        case loading
        case loaded([WorkoutInfo])
        case failed(String)
    }

    private struct PhotoTarget: Identifiable {
        let date: Date
        var id: Date { date }
    }

    private struct ViewerTarget: Identifiable {
        let assetIdentifier: String
        let cloudIdentifier: String?
        var id: String { assetIdentifier }
    }

    private struct NotesSheetTarget: Identifiable {
        let notes: [PhotoNote]
        var id: Date { notes.first?.pointDate ?? .distantPast }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(scope.title(for: interval))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    glucoseCard
                        .id(Self.glucoseCardID)
                    if !intervalNotes.isEmpty {
                        photoNotesCard
                    }
                    workoutCard
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                // 차트 밖 아무 곳이나 탭하면 값 선택을 푼다.
                // (차트 플롯이나 버튼 위의 탭은 각자의 제스처가 먼저 받아 여기로 오지 않는다.)
                .contentShape(Rectangle())
                .onTapGesture {
                    deselectSignal += 1
                }
            }
            .onChange(of: selectedWorkoutID) {
                // 아래 운동 목록에서 골랐을 때 확대된 차트가 보이도록 끌어올린다.
                guard selectedWorkoutID != nil else { return }
                withAnimation(.snappy) {
                    scrollProxy.scrollTo(Self.glucoseCardID, anchor: .top)
                }
            }
        }
        .task(id: taskKey) {
            await loadGlucose()
        }
        .refreshable {
            await refresh()
        }
        .sheet(item: $photoTarget) { target in
            MealPhotoSheet(pointDate: target.date) { assetIdentifier, memo, carbs in
                saveNote(
                    pointDate: target.date, assetIdentifier: assetIdentifier,
                    memo: memo, carbs: carbs)
            }
        }
        .fullScreenCover(item: $viewerTarget) { target in
            PhotoViewer(
                assetIdentifier: target.assetIdentifier,
                cloudIdentifier: target.cloudIdentifier)
        }
        .sheet(item: $editingNote) { note in
            PhotoNoteEditSheet(note: note) { memo, carbs in
                applyEdit(to: note, memo: memo, carbs: carbs)
            }
        }
        .sheet(item: $notesSheet) { target in
            PhotoNotesSheet(notes: target.notes)
        }
        .alert("건강 앱에 기록하지 못함", isPresented: .init(
            get: { carbsSaveError != nil },
            set: { if !$0 { carbsSaveError = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("메모는 저장되었지만 탄수화물을 건강 앱에 기록하지 못했습니다.\n\(carbsSaveError ?? "")")
        }
    }

    /// 메모를 저장하고, 탄수화물이 입력됐으면 건강 앱에도 기록한다.
    private func saveNote(pointDate: Date, assetIdentifier: String?, memo: String, carbs: Double?) {
        // 다른 기기에서도 같은 원본을 찾을 수 있도록 기기 공통 식별자를 함께 저장한다.
        let cloudIdentifier = assetIdentifier.flatMap {
            PhotoAssetLoader.cloudIdentifiers(forLocal: [$0])[$0]
        }
        let note = PhotoNote(
            pointDate: pointDate, assetIdentifier: assetIdentifier,
            assetCloudIdentifier: cloudIdentifier, memo: memo, carbsGrams: carbs)
        photoStore.add(note)
        guard let carbs else { return }
        Task {
            do {
                let sampleID = try await healthStore.saveCarbohydrates(
                    grams: carbs, at: pointDate, noteID: note.id)
                photoStore.setHealthSample(sampleID, for: note.id)
            } catch {
                carbsSaveError = error.localizedDescription
            }
        }
    }

    /// 수정 시트에서 바꾼 메모·탄수화물을 반영하고, 탄수화물이 바뀌었으면 건강 앱 기록도 갱신한다.
    private func applyEdit(to note: PhotoNote, memo: String, carbs: Double?) {
        var updated = note
        updated.memo = memo
        updated.carbsGrams = carbs
        photoStore.update(updated)
        guard note.carbsGrams != carbs else { return }
        Task {
            if let sampleID = note.healthSampleID {
                await healthStore.deleteCarbohydrateSample(id: sampleID)
                photoStore.setHealthSample(nil, for: note.id)
            }
            guard let carbs else { return }
            do {
                let sampleID = try await healthStore.saveCarbohydrates(
                    grams: carbs, at: note.pointDate, noteID: note.id)
                photoStore.setHealthSample(sampleID, for: note.id)
            } catch {
                carbsSaveError = error.localizedDescription
            }
        }
    }

    /// scope 전환으로 뷰가 재사용될 때도 다시 로드되도록 기간을 키로 쓴다.
    private var taskKey: String {
        "\(scope.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)"
    }

    private static let glucoseCardID = "glucoseCard"

    // MARK: - 혈당 카드

    private var glucoseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("혈당", systemImage: "drop.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.glucose)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let loadError {
                ContentUnavailableView(
                    "불러오기 실패",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
                .frame(minHeight: 220)
            } else if points.isEmpty {
                ContentUnavailableView(
                    "기록 없음",
                    systemImage: "drop",
                    description: Text("이 기간에는 혈당 기록이 없습니다."))
                .frame(minHeight: 220)
            } else {
                statsRow
                GlucoseChartView(
                    scope: scope, interval: interval, points: points,
                    workouts: loadedWorkouts, focusedWorkout: selectedWorkout,
                    photoNotes: intervalNotes,
                    onAddPhoto: { photoTarget = PhotoTarget(date: $0) },
                    onShowPhotoNotes: { notesSheet = NotesSheetTarget(notes: $0) },
                    deselectSignal: deselectSignal)
                .frame(height: 220)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("glucoseChart")
                if !loadedWorkouts.isEmpty {
                    workoutLegend
                }
                sourcesFootnote
                Text("탭하면 값 보기 · 두 번 탭하면 그 지점 확대 · 차트 밖을 탭하면 선택 해제 · 선택 후 사진 버튼으로 식사 사진·메모 추가")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var statsRow: some View {
        let values = points.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)
        return HStack(spacing: 0) {
            statItem("평균", value: average)
            Divider().frame(height: 36)
            statItem("최저", value: values.min() ?? 0)
            Divider().frame(height: 36)
            statItem("최고", value: values.max() ?? 0)
        }
    }

    private func statItem(_ title: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("mg/dL")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var loadedWorkouts: [WorkoutInfo] {
        if case .loaded(let workouts) = workoutState { return workouts }
        return []
    }

    /// 다시 조회해서 목록에서 빠진 운동은 선택도 풀린 것으로 본다.
    private var selectedWorkout: WorkoutInfo? {
        loadedWorkouts.first { $0.id == selectedWorkoutID }
    }

    private var workoutLegend: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.green.opacity(0.35))
                .frame(width: 14, height: 10)
            Text("운동 시간")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sourcesFootnote: some View {
        let sources = Set(points.map(\.source)).sorted()
        return Text("측정 \(points.count)건 · 출처: \(sources.joined(separator: ", "))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - 식사 사진·메모 카드

    private var intervalNotes: [PhotoNote] {
        photoStore.notes(in: interval)
    }

    private var photoNotesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("식사 사진·메모", systemImage: "photo.on.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 0) {
                ForEach(intervalNotes) { note in
                    PhotoNoteRow(
                        note: note,
                        onShowPhoto: {
                            if let assetIdentifier = note.assetIdentifier {
                                viewerTarget = ViewerTarget(
                                    assetIdentifier: assetIdentifier,
                                    cloudIdentifier: note.assetCloudIdentifier)
                            }
                        },
                        onEdit: { editingNote = note },
                        onDelete: {
                            if let sampleID = note.healthSampleID {
                                Task { await healthStore.deleteCarbohydrateSample(id: sampleID) }
                            }
                            photoStore.remove(note)
                        })
                    if note.id != intervalNotes.last?.id {
                        Divider().padding(.leading, 68)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - 운동 카드

    private var workoutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("운동", systemImage: "figure.run")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)

            switch workoutState {
            case .idle:
                Text("이 기간에 피트니스 앱 등으로 기록된 운동이 있는지 찾아봅니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    loadWorkouts()
                } label: {
                    Text("운동 조회하기")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.green)

            case .loading:
                ProgressView("운동 기록을 찾는 중…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                reloadWorkoutsButton

            case .loaded(let workouts):
                if workouts.isEmpty {
                    Label("이 기간에 기록된 운동이 없습니다.", systemImage: "moon.zzz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    Text("운동 \(workouts.count)건")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(workouts) { workout in
                            let isSelected = workout.id == selectedWorkout?.id
                            Button {
                                selectedWorkoutID = isSelected ? nil : workout.id
                            } label: {
                                WorkoutRow(workout: workout, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityHint(isSelected ? "선택 해제하고 전체 보기" : "차트에서 이 운동 구간 확대")
                            if workout.id != workouts.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
                // 하루에도 운동을 여러 번 할 수 있으니 언제든 다시 조회할 수 있게 둔다.
                reloadWorkoutsButton
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var reloadWorkoutsButton: some View {
        Button {
            loadWorkouts(forceRefresh: true)
        } label: {
            Label("다시 조회", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(.green)
    }

    // MARK: - 데이터 로드

    /// 아래로 당겨 새로고침: 혈당은 항상, 운동은 이미 조회한 적이 있을 때만 다시 읽는다.
    private func refresh() async {
        await fetchGlucose()
        switch workoutState {
        case .loaded, .failed:
            await fetchWorkouts(forceRefresh: true)
        case .idle, .loading:
            break
        }
    }

    private func loadGlucose() async {
        isLoading = true
        selectedWorkoutID = nil
        // 이전에 조회해 둔 운동 기록이 있으면 버튼을 다시 누르지 않아도 보여준다.
        if let cached = healthStore.cachedWorkouts(in: interval) {
            workoutState = .loaded(cached)
        } else {
            workoutState = .idle
        }
        await fetchGlucose()
        isLoading = false
    }

    /// 새로고침 중에는 기존 차트를 그대로 둔 채 결과만 바꿔 끼운다.
    private func fetchGlucose() async {
        do {
            points = try await healthStore.glucose(in: interval)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadWorkouts(forceRefresh: Bool = false) {
        workoutState = .loading
        Task {
            await fetchWorkouts(forceRefresh: forceRefresh)
        }
    }

    private func fetchWorkouts(forceRefresh: Bool) async {
        do {
            workoutState = .loaded(
                try await healthStore.workouts(in: interval, forceRefresh: forceRefresh))
        } catch {
            workoutState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 식사 사진·메모 행

struct PhotoNoteRow: View {
    let note: PhotoNote
    /// 썸네일을 누르면 사진을 크게 보여준다.
    let onShowPhoto: () -> Void
    /// 시각·메모 영역을 누르면 수정 시트를 띄운다.
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let assetIdentifier = note.assetIdentifier {
                Button(action: onShowPhoto) {
                    PhotoAssetImage(
                        assetIdentifier: assetIdentifier,
                        cloudIdentifier: note.assetCloudIdentifier)
                    .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사진 크게 보기")
            } else {
                Image(systemName: "note.text")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 48, height: 48)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
            }

            Button(action: onEdit) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(note.memo.isEmpty ? "메모 없음" : note.memo)
                            .font(.subheadline)
                            .foregroundStyle(note.memo.isEmpty ? .secondary : .primary)
                            .lineLimit(2)
                        if let carbs = note.carbsGrams {
                            Text(
                                note.healthSampleID != nil
                                    ? "탄수화물 \(PhotoNote.gramsText(carbs))g · 건강 앱에 기록됨"
                                    : "탄수화물 \(PhotoNote.gramsText(carbs))g")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("메모 수정")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("이 메모 삭제")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d (E) a h:mm"
        return formatter.string(from: note.pointDate)
    }
}

// MARK: - 운동 행

struct WorkoutRow: View {
    let workout: WorkoutInfo
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbolName)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(.green.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activityName)
                    .font(.subheadline.weight(.medium))
                Text("\(timeRangeText) · \(workout.source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(.green.opacity(isSelected ? 0.12 : 0), in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d a h:mm"
        return formatter.string(from: workout.start)
    }

    private var durationText: String {
        let minutes = Int(workout.duration / 60)
        if minutes >= 60 {
            return "\(minutes / 60)시간 \(minutes % 60)분"
        }
        return "\(minutes)분"
    }

    private var detailText: String? {
        var parts: [String] = []
        if let calories = workout.calories {
            parts.append("\(Int(calories.rounded()))kcal")
        }
        if let distance = workout.distanceMeters, distance > 0 {
            parts.append(String(format: "%.2fkm", distance / 1000))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
