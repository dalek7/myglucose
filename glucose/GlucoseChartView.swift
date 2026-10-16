import Charts
import SwiftUI

/// 건강 앱 스타일의 혈당 차트.
/// 일 단위에서는 측정점(CGM처럼 촘촘하면 선 연결), 주 단위에서는 측정값을 이은 시계열 선,
/// 월 단위에서는 일별 최저~최고 범위 막대를 그린다. 월을 이틀 이하로 확대하면 측정값을 자세히 보여준다.
struct GlucoseChartView: View {
    let scope: TimeScope
    let interval: DateInterval
    let points: [GlucosePoint]
    var workouts: [WorkoutInfo] = []
    /// 목록에서 고른 운동. 바뀌면 그 구간으로 확대한다.
    var focusedWorkout: WorkoutInfo?
    /// 이 기간에 저장된 식사 사진·메모. 측정값 보기에서 배지로 표시한다.
    var photoNotes: [PhotoNote] = []
    /// 측정점을 선택한 상태에서 사진 버튼을 누르면 그 측정 시각으로 호출된다.
    var onAddPhoto: ((Date) -> Void)?
    /// 바깥(차트 밖 화면)을 탭했을 때 값이 바뀌면 선택을 푼다.
    var deselectSignal: Int = 0

    private struct DayRange: Identifiable {
        let id: Date
        let min: Double
        let max: Double
        let avg: Double

        // 측정이 1건이어서 범위가 0에 가까우면 보이도록 최소 두께를 준다.
        var displayMin: Double { max - min < 3 ? min - 1.5 : min }
        var displayMax: Double { max - min < 3 ? max + 1.5 : max }
    }

    private struct LinePoint: Identifiable {
        let id: UUID
        let date: Date
        let value: Double
        /// 같은 값끼리만 선으로 잇는다.
        let segment: Int
    }

    /// 참고용 목표 범위 (mg/dL)
    private let targetRange: ClosedRange<Double> = 70...180

    /// 현재 보이는 가로 구간 길이(초). 기간 전체면 줌이 없는 상태다.
    @State private var visibleSeconds: TimeInterval
    /// 보이는 구간의 시작 시각.
    @State private var windowStart: Date
    @State private var pinchBaseSeconds: TimeInterval?
    @State private var pinchAnchor: Date?
    @State private var dragBaseStart: Date?
    @State private var chartWidth: CGFloat = 350
    /// 탭/스크럽으로 선택된 지점 (일: 측정 시각, 주/월: 날짜).
    @State private var selectedDate: Date?

    init(
        scope: TimeScope, interval: DateInterval,
        points: [GlucosePoint], workouts: [WorkoutInfo] = [],
        focusedWorkout: WorkoutInfo? = nil,
        photoNotes: [PhotoNote] = [],
        onAddPhoto: ((Date) -> Void)? = nil,
        deselectSignal: Int = 0
    ) {
        self.scope = scope
        self.interval = interval
        self.points = points
        self.workouts = workouts
        self.focusedWorkout = focusedWorkout
        self.photoNotes = photoNotes
        self.onAddPhoto = onAddPhoto
        self.deselectSignal = deselectSignal
        _visibleSeconds = State(initialValue: interval.duration)
        _windowStart = State(initialValue: interval.start)
    }

    private var isZoomed: Bool {
        visibleSeconds < interval.duration * 0.98
    }

    /// 이 길이 이하로 확대하면 주/월에서도 측정값을 시계열로 자세히 보여준다.
    private static let detailThreshold: TimeInterval = 2 * 86400

    private var isDetailZoom: Bool {
        scope != .day && visibleSeconds <= Self.detailThreshold
    }

    /// 월 전체 보기는 선이 너무 촘촘해 측정값 대신 일별 범위 막대를 그린다.
    private var showsLine: Bool { scope != .month || isDetailZoom }

    /// 측정값을 그릴 때는 측정점 단위로, 범위 막대를 그릴 때는 날짜 단위로 선택한다.
    private var selectsPoints: Bool { showsLine }

    /// 주 전체 보기는 일주일치 선이 한 화면에 들어가 선과 점을 가늘게 그린다.
    private var isWeekOverview: Bool { scope == .week && !isDetailZoom }

    var body: some View {
        // Charts 내장 가로 스크롤은 줌이 없을 때도 드래그를 가로채
        // 타임라인 페이지 스와이프를 막기 때문에, X축 도메인을 직접 조작한다.
        // 줌 전에는 차트가 완전히 정적이라 스와이프가 그대로 통과한다.
        chartBody
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if width > 0 { chartWidth = width }
            }
            // 팬은 줌 상태에서만 활성화한다 (줌 전에는 페이지 스와이프에 양보).
            // .subviews/.all 마스크로 오버레이의 선택 제스처는 항상 살려 둔다.
            .gesture(panGesture, including: isZoomed ? .all : .subviews)
            .simultaneousGesture(magnifyGesture)
            .onChange(of: deselectSignal) {
                selectedDate = nil
            }
            .onChange(of: interval) {
                resetZoom()
                selectedDate = nil
            }
            .onChange(of: focusedWorkout?.id) {
                withAnimation(.snappy) {
                    if let focusedWorkout {
                        focus(on: focusedWorkout)
                    } else {
                        resetZoom()
                    }
                }
            }
            .onChange(of: selectsPoints) { _, pointsMode in
                // 확대 단계에 따라 선택 단위(측정점↔날짜)가 바뀌면 가장 가까운 대상으로 옮긴다.
                guard let date = selectedDate else { return }
                select(near: pointsMode ? date.addingTimeInterval(12 * 3600) : date, toggleIfSame: false)
            }
            .onAppear {
                if let focusedWorkout { focus(on: focusedWorkout) }
            }
    }

    // MARK: - 줌/팬

    /// 최대로 확대했을 때 보이는 구간 길이. 주/월도 측정값을 볼 수 있도록 일 단위와 같다.
    private let minVisibleSeconds: TimeInterval = 3600

    /// 돋보기 버튼 한 번에 바뀌는 배율.
    private static let zoomStep: Double = 2

    private func resetZoom() {
        visibleSeconds = interval.duration
        windowStart = interval.start
    }

    private func clampedWindowStart(_ date: Date, length: TimeInterval) -> Date {
        let latest = interval.end.addingTimeInterval(-length)
        return Swift.min(Swift.max(date, interval.start), latest)
    }

    /// 앵커 시각이 화면에서 같은 위치에 머물도록 보이는 구간 길이를 바꾼다.
    private func setVisibleLength(_ proposed: TimeInterval, anchor: Date) {
        let length = Swift.min(Swift.max(proposed, minVisibleSeconds), interval.duration)
        let fraction = anchor.timeIntervalSince(windowStart) / visibleSeconds
        windowStart = clampedWindowStart(
            anchor.addingTimeInterval(-fraction * length), length: length)
        visibleSeconds = length
    }

    private func zoom(by factor: Double) {
        setVisibleLength(visibleSeconds / factor, anchor: zoomAnchor)
    }

    /// 확대/축소의 기준점: 화면에 보이는 선택 지점 → 고른 운동의 가운데 → 화면 가운데 순.
    /// 팬으로 기준점을 화면 밖으로 밀어냈다면 지금 보고 있는 곳을 기준으로 삼는다.
    private var zoomAnchor: Date {
        let window = DateInterval(start: windowStart, duration: visibleSeconds)
        if let date = selectionAnchor, window.contains(date) { return date }
        if let workout = focusedWorkout {
            let middle = workout.start.addingTimeInterval(workout.duration / 2)
            if window.contains(middle) { return middle }
        }
        return windowStart.addingTimeInterval(visibleSeconds / 2)
    }

    /// 운동 화면에서 운동 구간이 차지하는 비율. 나머지는 운동 전후의 혈당 변화를 보여준다.
    private static let workoutFocusRatio: Double = 0.25

    /// 운동 구간이 화면 가운데 1/4을 차지하게 맞춘다.
    /// 15분이 안 되는 짧은 운동만 최대 확대 폭에 걸려 1/4보다 좁게 보인다.
    private func focus(on workout: WorkoutInfo) {
        let start = Swift.max(workout.start, interval.start)
        let end = Swift.min(workout.end, interval.end)
        guard end >= start else { return }
        let span = end.timeIntervalSince(start)
        let length = Swift.min(
            Swift.max(span / Self.workoutFocusRatio, minVisibleSeconds), interval.duration)
        let middle = start.addingTimeInterval(span / 2)
        windowStart = clampedWindowStart(middle.addingTimeInterval(-length / 2), length: length)
        visibleSeconds = length
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseSeconds ?? visibleSeconds
                if pinchBaseSeconds == nil { pinchBaseSeconds = base }
                let anchor = pinchAnchor ?? zoomAnchor
                if pinchAnchor == nil { pinchAnchor = anchor }
                guard value.magnification > 0 else { return }
                setVisibleLength(base / value.magnification, anchor: anchor)
            }
            .onEnded { _ in
                pinchBaseSeconds = nil
                pinchAnchor = nil
            }
    }

    /// 선택한 지점이나 운동이 있을 때, 또는 더블 탭 등으로 확대한 상태면 돋보기 버튼을 보여준다.
    private var showsZoomControls: Bool {
        selectionAnchor != nil || focusedWorkout != nil || isZoomed
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton(
                "minus.magnifyingglass", label: "축소", identifier: "zoomOut",
                enabled: isZoomed
            ) {
                zoom(by: 1 / Self.zoomStep)
            }
            Divider().frame(height: 18)
            zoomButton(
                "plus.magnifyingglass", label: "확대", identifier: "zoomIn",
                enabled: visibleSeconds > minVisibleSeconds + 1
            ) {
                zoom(by: Self.zoomStep)
            }
            // 측정점을 골랐을 때만 그 시각 전후의 식사 사진을 붙일 수 있다.
            if let onAddPhoto, let point = selectedPoint {
                Divider().frame(height: 18)
                Button {
                    onAddPhoto(point.date)
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("식사 사진·메모 추가")
                .accessibilityIdentifier("addPhoto")
            }
        }
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func zoomButton(
        _ symbol: String, label: String, identifier: String, enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let base = dragBaseStart ?? windowStart
                if dragBaseStart == nil { dragBaseStart = base }
                let secondsPerPoint = visibleSeconds / Double(chartWidth)
                let shifted = base.addingTimeInterval(
                    -Double(value.translation.width) * secondsPerPoint)
                windowStart = clampedWindowStart(shifted, length: visibleSeconds)
            }
            .onEnded { _ in
                dragBaseStart = nil
            }
    }

    private var chartBody: some View {
        Chart {
            RectangleMark(
                xStart: .value("시작", interval.start),
                xEnd: .value("끝", interval.end),
                yStart: .value("목표 하한", targetRange.lowerBound),
                yEnd: .value("목표 상한", targetRange.upperBound)
            )
            .foregroundStyle(.green.opacity(0.07))

            // 조회된 운동의 시작~끝 구간을 초록 띠로 표시 (고른 운동은 진하게)
            ForEach(workouts) { workout in
                let span = displaySpan(for: workout)
                RectangleMark(
                    xStart: .value("운동 시작", span.lowerBound),
                    xEnd: .value("운동 종료", span.upperBound)
                )
                .foregroundStyle(.green.opacity(workoutBandOpacity(workout)))
                .annotation(position: .overlay, alignment: .top) {
                    if scope == .day || isDetailZoom {
                        Image(systemName: workout.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.top, 4)
                    }
                }
            }

            if showsLine {
                // 주 단위는 드문드문 잰 값도 시계열로 잇는다.
                if isDense || scope == .week {
                    ForEach(linePoints) { point in
                        LineMark(
                            x: .value("시각", point.date),
                            y: .value("혈당", point.value),
                            series: .value("구간", point.segment)
                        )
                        .foregroundStyle(Color.glucose)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: isWeekOverview ? 1.5 : 2))
                    }
                }
                if !isDense {
                    ForEach(points) { point in
                        PointMark(
                            x: .value("시각", point.date),
                            y: .value("혈당", point.value)
                        )
                        .foregroundStyle(Color.glucose)
                        .symbolSize(isWeekOverview ? 18 : 60)
                    }
                }
            } else {
                ForEach(dayRanges) { day in
                    RectangleMark(
                        x: .value("날짜", day.id, unit: .day),
                        yStart: .value("최저", day.displayMin),
                        yEnd: .value("최고", day.displayMax),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(Color.glucose.gradient)
                    .cornerRadius(4)
                }
            }

            // 저장된 식사 사진·메모 위치를 측정값 보기에서 배지로 표시한다.
            if showsLine {
                ForEach(visiblePhotoNotes) { note in
                    // 배지에서 그 시각의 혈당 값까지 은은한 점선 보조선을 올린다.
                    if let value = glucoseValue(near: note.pointDate) {
                        RuleMark(
                            x: .value("사진 메모", note.pointDate),
                            yStart: .value("혈당", yDomain.lowerBound),
                            yEnd: .value("혈당", value)
                        )
                        .foregroundStyle(.orange.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    PointMark(
                        x: .value("사진 메모", note.pointDate),
                        y: .value("혈당", yDomain.lowerBound)
                    )
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: note.assetIdentifier == nil ? "note.text" : "photo.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            selectionMarks
        }
        .chartXScale(domain: windowStart...windowStart.addingTimeInterval(visibleSeconds))
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .chartYScale(domain: yDomain)
        .chartXAxis { xAxisMarks }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.25))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(chartTapGestures(proxy: proxy, geo: geo))

                // 데이터가 적은 플롯 왼쪽 아래 구석에 둔다 (위쪽은 선택 카드 자리).
                if showsZoomControls, let plotFrame = proxy.plotFrame {
                    let plot = geo[plotFrame]
                    zoomControls
                        .padding(6)
                        .frame(width: plot.width, height: plot.height, alignment: .bottomLeading)
                        .offset(x: plot.minX, y: plot.minY)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsZoomControls)
        }
    }

    private func workoutBandOpacity(_ workout: WorkoutInfo) -> Double {
        guard let focusedWorkout else { return 0.22 }
        return workout.id == focusedWorkout.id ? 0.4 : 0.12
    }

    /// 보이는 구간 밖의 배지는 플롯 밖으로 그려지지 않도록 걸러낸다.
    private var visiblePhotoNotes: [PhotoNote] {
        let window = DateInterval(start: windowStart, duration: visibleSeconds)
        return photoNotes.filter { window.contains($0.pointDate) }
    }

    /// 메모 시각의 혈당 값. 같은 시각 측정이 없으면 30분 이내에서 가장 가까운 값을 쓴다.
    /// 그보다 멀면 보조선이 엉뚱한 높이를 가리키므로 긋지 않는다.
    private func glucoseValue(near date: Date) -> Double? {
        let nearest = points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        guard let nearest, abs(nearest.date.timeIntervalSince(date)) <= 1800 else { return nil }
        return nearest.value
    }

    // MARK: - 값 선택

    private var selectedPoint: GlucosePoint? {
        guard selectsPoints, let selectedDate else { return nil }
        return points.first { $0.date == selectedDate }
    }

    private var selectedDayRange: DayRange? {
        guard !selectsPoints, let selectedDate else { return nil }
        return dayRanges.first { $0.id == selectedDate }
    }

    /// 화면에 표시 중인 선택 지점의 시각 (날짜 선택이면 그날 한가운데).
    private var selectionAnchor: Date? {
        if let point = selectedPoint { return point.date }
        if let day = selectedDayRange { return day.id.addingTimeInterval(12 * 3600) }
        return nil
    }

    @ChartContentBuilder
    private var selectionMarks: some ChartContent {
        if let point = selectedPoint {
            RuleMark(x: .value("선택 시각", point.date))
                .foregroundStyle(Color.gray.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(
                    position: .top, alignment: .center,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    selectionCard(
                        title: scope == .day
                            ? Self.timeLabel(point.date) : Self.dayTimeLabel(point.date),
                        valueText: "\(Int(point.value.rounded()))")
                }
            PointMark(x: .value("선택 시각", point.date), y: .value("혈당", point.value))
                .symbolSize(150)
                .foregroundStyle(.white)
            PointMark(x: .value("선택 시각", point.date), y: .value("혈당", point.value))
                .symbolSize(80)
                .foregroundStyle(Color.glucose)
        } else if let day = selectedDayRange {
            RuleMark(x: .value("선택 날짜", day.id, unit: .day))
                .foregroundStyle(Color.gray.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(
                    position: .top, alignment: .center,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    selectionCard(
                        title: Self.dayLabel(day.id),
                        valueText: day.min == day.max
                            ? "\(Int(day.min.rounded()))"
                            : "\(Int(day.min.rounded()))–\(Int(day.max.rounded()))")
                }
        }
    }

    private func selectionCard(title: String, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(valueText)
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityIdentifier("selectionValue")
                Text("mg/dL")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("selectionCard")
        .accessibilityLabel("\(title) \(valueText) mg/dL")
    }

    private func dateAt(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        return proxy.value(atX: location.x - origin.x)
    }

    /// 한 번 탭하면 가까운 값 선택, 두 번 탭하면 그 지점을 중심으로 부드럽게 확대.
    /// exclusively로 묶어 더블 탭이 선택 토글로 새지 않게 한다.
    private func chartTapGestures(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        let doubleTap = SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let date = dateAt(value.location, proxy: proxy, geo: geo) else { return }
                withAnimation(.snappy) {
                    setVisibleLength(visibleSeconds / Self.zoomStep, anchor: date)
                }
            }
        let singleTap = SpatialTapGesture()
            .onEnded { value in
                guard let date = dateAt(value.location, proxy: proxy, geo: geo) else { return }
                select(near: date, toggleIfSame: true)
            }
        return doubleTap.exclusively(before: singleTap)
    }

    private func select(near date: Date, toggleIfSame: Bool) {
        let nearest: Date?
        if selectsPoints {
            nearest = points.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }?.date
        } else {
            let day = Calendar.current.startOfDay(for: date)
            nearest = dayRanges.min {
                abs($0.id.timeIntervalSince(day)) < abs($1.id.timeIntervalSince(day))
            }?.id
        }
        guard let nearest else { return }
        if toggleIfSame, selectedDate == nearest {
            selectedDate = nil
        } else {
            selectedDate = nearest
        }
    }

    private static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter.string(from: date)
    }

    private static func dayTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d (E) a h:mm"
        return formatter.string(from: date)
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    /// 운동 구간을 기간 안으로 자르고, 보이는 구간에 비해 너무 짧으면 보이도록 최소 폭을 보장한다.
    /// 최소 폭을 확대 정도에 맞춰야 확대했을 때 운동 띠가 실제보다 넓게 그려지지 않는다.
    private func displaySpan(for workout: WorkoutInfo) -> ClosedRange<Date> {
        // 하루 전체 보기에서 20분, 주 전체 보기에서 약 2시간 20분
        let minWidth = visibleSeconds / 72
        var start = Swift.max(workout.start, interval.start)
        var end = Swift.min(workout.end, interval.end)
        if end.timeIntervalSince(start) < minWidth {
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            start = Swift.max(mid.addingTimeInterval(-minWidth / 2), interval.start)
            end = Swift.min(start.addingTimeInterval(minWidth), interval.end)
        }
        return start...Swift.max(end, start)
    }

    // MARK: - 데이터 가공

    /// 하루 24건 초과면 CGM으로 보고 선으로 연결한다.
    /// 주/월은 기간 전체의 건수라 하루 평균으로 따진다.
    private var isDense: Bool {
        Double(points.count) / Swift.max(1, interval.duration / 86400) > 24
    }

    /// CGM 데이터가 센서 교체 등으로 1시간 넘게 끊긴 곳은 선을 잇지 않는다.
    private var linePoints: [LinePoint] {
        var segment = 0
        var previous: Date?
        return points.map { point in
            if isDense, let previous, point.date.timeIntervalSince(previous) > 3600 {
                segment += 1
            }
            previous = point.date
            return LinePoint(id: point.id, date: point.date, value: point.value, segment: segment)
        }
    }

    private var dayRanges: [DayRange] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: points) { calendar.startOfDay(for: $0.date) }
        return grouped.map { day, samples in
            let values = samples.map(\.value)
            return DayRange(
                id: day,
                min: values.min() ?? 0,
                max: values.max() ?? 0,
                avg: values.reduce(0, +) / Double(values.count))
        }
        .sorted { $0.id < $1.id }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let lower = Swift.min(60, (values.min() ?? 60) - 15)
        let upper = Swift.max(200, (values.max() ?? 200) + 15)
        return max(0, lower)...upper
    }

    /// 확대할수록 눈금을 조밀하게 보여준다.
    private var hourStride: Int {
        let visibleHours = visibleSeconds / 3600
        if visibleHours <= 4 { return 1 }
        if visibleHours <= 10 { return 2 }
        if visibleHours <= 16 { return 3 }
        if visibleHours <= 24 { return 6 }
        return 12
    }

    private var dayStride: Int {
        let visibleDays = visibleSeconds / 86400
        return visibleDays <= 12 ? 1 : 7
    }

    @AxisContentBuilder
    private var xAxisMarks: some AxisContent {
        if scope == .day || isDetailZoom {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.25))
                AxisValueLabel(format: .dateTime.hour().locale(Locale(identifier: "ko_KR")))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        } else if scope == .week {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.25))
                AxisValueLabel(
                    format: .dateTime.weekday(.narrow).locale(Locale(identifier: "ko_KR")),
                    centered: true)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            }
        } else {
            AxisMarks(values: .stride(by: .day, count: dayStride)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.25))
                AxisValueLabel(format: .dateTime.day().locale(Locale(identifier: "ko_KR")))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}
