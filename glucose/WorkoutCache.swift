import Foundation

/// 한번 조회한 운동 기록을 기간별로 기억해 두는 저장소. 앱을 다시 켜도 유지되도록 파일에 저장한다.
struct WorkoutCache: Codable {
    private struct Entry: Codable {
        let interval: DateInterval
        var workouts: [WorkoutInfo]
    }

    private var entries: [Entry] = []

    /// 같은 기간을 조회했거나, 이 기간을 포함하는 더 넓은 기간(주·월)을 조회해 둔 적이 있으면 그 결과를 돌려준다.
    func workouts(in interval: DateInterval) -> [WorkoutInfo]? {
        if let exact = entries.first(where: { $0.interval == interval }) {
            return exact.workouts
        }
        guard let covering = entries.first(where: {
            $0.interval.start <= interval.start && $0.interval.end >= interval.end
        }) else { return nil }
        return covering.workouts.filter { $0.overlaps(interval) }
    }

    /// 새로 조회한 결과를 기억하고, 겹치는 다른 기간의 기억도 같은 결과로 맞춰 둔다.
    mutating func store(_ fresh: [WorkoutInfo], for interval: DateInterval) {
        for index in entries.indices where entries[index].interval != interval {
            let key = entries[index].interval
            guard key.intersects(interval) else { continue }
            let kept = entries[index].workouts.filter { !$0.overlaps(interval) }
            let added = fresh.filter { $0.overlaps(key) }
            entries[index].workouts = (kept + added).sorted { $0.start < $1.start }
        }
        if let index = entries.firstIndex(where: { $0.interval == interval }) {
            entries[index].workouts = fresh
        } else {
            entries.append(Entry(interval: interval, workouts: fresh))
        }
    }
}

// MARK: - 파일 저장

extension WorkoutCache {
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "workout-cache.json")
    }

    static func load(from url: URL = defaultURL) -> WorkoutCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(WorkoutCache.self, from: data)
        else { return WorkoutCache() }
        return cache
    }

    func save(to url: URL = Self.defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 건강 데이터이므로 기기가 잠겨 있을 때는 읽을 수 없게 저장한다.
            try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("workout cache save failed: \(error)")
        }
    }
}

extension WorkoutInfo {
    /// HealthKit 조회와 같은 기준: 기간과 조금이라도 겹치면 포함한다.
    func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && end > interval.start
    }
}
