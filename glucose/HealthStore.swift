import Foundation
import HealthKit
import Observation

// MARK: - 모델

struct GlucosePoint: Identifiable {
    let id = UUID()
    let date: Date
    /// mg/dL
    let value: Double
    let source: String
}

struct WorkoutInfo: Identifiable, Codable {
    let id: UUID
    let activityName: String
    let symbolName: String
    let start: Date
    let end: Date
    let duration: TimeInterval
    let calories: Double?
    let distanceMeters: Double?
    let source: String
}

enum HealthError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "이 기기에서는 건강 데이터를 사용할 수 없습니다."
        }
    }
}

// MARK: - HealthKit 접근

@Observable
final class HealthStore {
    private let store = HKHealthStore()
    private static let mgdL = HKUnit(from: "mg/dL")

    var authorizationRequested = false

    /// 한번 조회한 운동 기록은 기간별로 기억해 두고, 앱을 다시 켜도 이어서 쓴다.
    private var workoutCache: WorkoutCache

    init() {
#if DEBUG
        // UI 테스트는 매번 같은 상태에서 시작하도록 기억해 둔 운동 기록을 비운다.
        if ProcessInfo.processInfo.arguments.contains("--reset-workout-cache") {
            workoutCache = WorkoutCache()
            workoutCache.save()
            return
        }
#endif
        workoutCache = WorkoutCache.load()
    }

    func cachedWorkouts(in interval: DateInterval) -> [WorkoutInfo]? {
        workoutCache.workouts(in: interval)
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.bloodGlucose),
            .workoutType(),
        ]
        try await store.requestAuthorization(toShare: [], read: readTypes)
        authorizationRequested = true
    }

    // MARK: - 식사 탄수화물 기록

    /// 식사 메모에 입력한 탄수화물 섭취량을 건강 앱에 기록하고 샘플 UUID를 돌려준다.
    /// 쓰기 권한은 처음 기록할 때 요청한다.
    func saveCarbohydrates(grams: Double, at date: Date, noteID: UUID) async throws -> UUID {
        let type = HKQuantityType(.dietaryCarbohydrates)
        try await store.requestAuthorization(toShare: [type], read: [])
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .gram(), doubleValue: grams),
            start: date, end: date,
            metadata: [HKMetadataKeyExternalUUID: noteID.uuidString])
        try await store.save(sample)
        return sample.uuid
    }

    /// 메모를 지울 때 함께 기록했던 탄수화물 샘플도 지운다. (이 앱이 만든 샘플만 지울 수 있다.)
    func deleteCarbohydrateSample(id: UUID) async {
        do {
            try await store.deleteObjects(
                of: HKQuantityType(.dietaryCarbohydrates),
                predicate: HKQuery.predicateForObject(with: id))
        } catch {
            print("carbohydrate sample delete failed: \(error)")
        }
    }

#if DEBUG
    /// UI 테스트/시뮬레이터 확인용 데모 데이터. `--seed-demo` 실행 인자가 있을 때만 동작한다.
    func seedDemoDataIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--seed-demo") else { return }
        do {
            let glucoseType = HKQuantityType(.bloodGlucose)
            let energyType = HKQuantityType(.activeEnergyBurned)
            let shareTypes: Set<HKSampleType> = [glucoseType, .workoutType(), energyType]
            let readTypes: Set<HKObjectType> = [glucoseType, .workoutType()]
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)

            // 이미 시딩되어 있으면 건너뛴다.
            let existing = try await glucose(
                in: DateInterval(start: Date().addingTimeInterval(-3 * 86400), end: Date()))
            guard existing.isEmpty else { return }

            // 지난 3일간 15분 간격의 CGM 유사 곡선
            var samples: [HKQuantitySample] = []
            let now = Date()
            var t = now.addingTimeInterval(-3 * 86400)
            while t < now {
                let hours = t.timeIntervalSinceReferenceDate / 3600
                let value = 115
                    + 30 * sin(hours / 3.8)
                    + 18 * sin(hours / 1.3)
                    + Double.random(in: -6...6)
                samples.append(HKQuantitySample(
                    type: glucoseType,
                    quantity: HKQuantity(unit: Self.mgdL, doubleValue: max(62, min(230, value))),
                    start: t, end: t))
                t.addTimeInterval(15 * 60)
            }
            try await store.save(samples)

            let calendar = Calendar.current
            let todayMorning = calendar.date(
                bySettingHour: 7, minute: 30, second: 0, of: now) ?? now
            try await seedWorkout(.running, start: todayMorning, minutes: 32, kcal: 310)
            try await seedWorkout(
                .stairs,
                start: todayMorning.addingTimeInterval(-86400 + 11 * 3600),
                minutes: 48, kcal: 240)
        } catch {
            print("demo seed failed: \(error)")
        }
    }

    private func seedWorkout(
        _ activity: HKWorkoutActivityType, start: Date, minutes: Double, kcal: Double
    ) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        let end = start.addingTimeInterval(minutes * 60)
        try await builder.beginCollection(at: start)
        let energy = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
            start: start, end: end)
        try await builder.addSamples([energy])
        try await builder.endCollection(at: end)
        try await builder.finishWorkout()
    }
#endif

    func glucose(in interval: DateInterval) async throws -> [GlucosePoint] {
        let datePredicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bloodGlucose), predicate: datePredicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = try await descriptor.result(for: store)
        return samples.map {
            GlucosePoint(
                date: $0.startDate,
                value: $0.quantity.doubleValue(for: Self.mgdL),
                source: $0.sourceRevision.source.name)
        }
    }

    /// `forceRefresh`가 true면 캐시를 무시하고 HealthKit에서 다시 읽어 캐시를 갱신한다.
    func workouts(in interval: DateInterval, forceRefresh: Bool = false) async throws -> [WorkoutInfo] {
        if !forceRefresh, let cached = workoutCache.workouts(in: interval) {
            return cached
        }
        let datePredicate = HKQuery.predicateForSamples(
            withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(datePredicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let workouts = try await descriptor.result(for: store)
        let infos = workouts.map { workout in
            let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            let distanceTypes: [HKQuantityType] = [
                HKQuantityType(.distanceWalkingRunning),
                HKQuantityType(.distanceCycling),
                HKQuantityType(.distanceSwimming),
            ]
            let distance = distanceTypes.lazy
                .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
                .first
            return WorkoutInfo(
                id: workout.uuid,
                activityName: workout.workoutActivityType.koreanName,
                symbolName: workout.workoutActivityType.symbolName,
                start: workout.startDate,
                end: workout.endDate,
                duration: workout.duration,
                calories: calories,
                distanceMeters: distance,
                source: workout.sourceRevision.source.name)
        }
        workoutCache.store(infos, for: interval)
        workoutCache.save()
        return infos
    }
}

// MARK: - 운동 종류 표시

extension HKWorkoutActivityType {
    var koreanName: String {
        switch self {
        case .running: return "달리기"
        case .walking: return "걷기"
        case .cycling: return "사이클링"
        case .swimming: return "수영"
        case .hiking: return "하이킹"
        case .yoga: return "요가"
        case .pilates: return "필라테스"
        case .functionalStrengthTraining: return "기능성 근력 운동"
        case .traditionalStrengthTraining: return "근력 운동"
        case .highIntensityIntervalTraining: return "고강도 인터벌 트레이닝"
        case .coreTraining: return "코어 운동"
        case .elliptical: return "일립티컬"
        case .rowing: return "로잉"
        case .stairs: return "계단 오르기"
        case .stairClimbing: return "계단 오르기 머신"
        case .stepTraining: return "스텝 운동"
        case .jumpRope: return "줄넘기"
        case .kickboxing: return "킥복싱"
        case .taiChi: return "태극권"
        case .barre: return "바레"
        case .volleyball: return "배구"
        case .downhillSkiing: return "스키"
        case .snowboarding: return "스노보드"
        case .surfingSports: return "서핑"
        case .fishing: return "낚시"
        case .wheelchairWalkPace, .wheelchairRunPace: return "휠체어"
        case .dance, .socialDance, .cardioDance: return "댄스"
        case .soccer: return "축구"
        case .basketball: return "농구"
        case .baseball: return "야구"
        case .tennis: return "테니스"
        case .tableTennis: return "탁구"
        case .badminton: return "배드민턴"
        case .golf: return "골프"
        case .climbing: return "클라이밍"
        case .boxing: return "복싱"
        case .martialArts: return "무술"
        case .crossTraining: return "크로스 트레이닝"
        case .mixedCardio: return "혼합 유산소"
        case .cooldown: return "마무리 운동"
        case .flexibility: return "유연성 운동"
        case .mindAndBody: return "심신 단련"
        default: return "운동"
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .hiking: return "figure.hiking"
        case .yoga: return "figure.yoga"
        case .pilates: return "figure.pilates"
        case .functionalStrengthTraining, .traditionalStrengthTraining:
            return "figure.strengthtraining.traditional"
        case .highIntensityIntervalTraining: return "figure.highintensity.intervaltraining"
        case .coreTraining: return "figure.core.training"
        case .elliptical: return "figure.elliptical"
        case .rowing: return "figure.rower"
        case .stairs: return "figure.stairs"
        case .stairClimbing, .stepTraining: return "figure.stair.stepper"
        case .jumpRope: return "figure.jumprope"
        case .kickboxing: return "figure.kickboxing"
        case .taiChi: return "figure.taichi"
        case .barre: return "figure.barre"
        case .volleyball: return "figure.volleyball"
        case .downhillSkiing: return "figure.skiing.downhill"
        case .snowboarding: return "figure.snowboarding"
        case .surfingSports: return "figure.surfing"
        case .fishing: return "figure.fishing"
        case .wheelchairWalkPace, .wheelchairRunPace: return "figure.roll"
        case .dance, .socialDance, .cardioDance: return "figure.dance"
        case .soccer: return "figure.indoor.soccer"
        case .basketball: return "figure.basketball"
        case .baseball: return "figure.baseball"
        case .tennis: return "figure.tennis"
        case .tableTennis: return "figure.table.tennis"
        case .badminton: return "figure.badminton"
        case .golf: return "figure.golf"
        case .climbing: return "figure.climbing"
        case .boxing: return "figure.boxing"
        case .martialArts: return "figure.martial.arts"
        case .mixedCardio, .crossTraining: return "figure.mixed.cardio"
        case .cooldown, .flexibility: return "figure.cooldown"
        case .mindAndBody: return "figure.mind.and.body"
        default: return "figure.mixed.cardio"
        }
    }
}
