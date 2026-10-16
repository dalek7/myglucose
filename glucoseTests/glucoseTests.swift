//
//  glucoseTests.swift
//  glucoseTests
//
//  Created by Seung-Chan Kim on 10/3/26.
//

import Foundation
import Testing
@testable import glucose

@MainActor
struct WorkoutCacheTests {
    private let day1 = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86400)
    private let day2 = DateInterval(start: Date(timeIntervalSince1970: 86400), duration: 86400)
    private var week: DateInterval { DateInterval(start: day1.start, duration: 7 * 86400) }

    private func workout(at offset: TimeInterval, minutes: Double = 30) -> WorkoutInfo {
        let start = Date(timeIntervalSince1970: offset)
        return WorkoutInfo(
            id: UUID(), activityName: "달리기", symbolName: "figure.run",
            start: start, end: start.addingTimeInterval(minutes * 60),
            duration: minutes * 60, calories: 300, distanceMeters: nil, source: "test")
    }

    @Test func remembersQueriedInterval() {
        var cache = WorkoutCache()
        #expect(cache.workouts(in: day1) == nil)
        cache.store([], for: day1)
        #expect(cache.workouts(in: day1)?.isEmpty == true, "운동이 없다는 결과도 기억해야 한다")
    }

    @Test func narrowerIntervalUsesWiderResult() {
        var cache = WorkoutCache()
        let first = workout(at: 3600)
        let second = workout(at: 86400 + 3600)
        cache.store([first, second], for: week)
        #expect(cache.workouts(in: day1)?.map(\.id) == [first.id])
        #expect(cache.workouts(in: day2)?.map(\.id) == [second.id])
    }

    @Test func refreshUpdatesOverlappingIntervals() {
        var cache = WorkoutCache()
        let old = workout(at: 3600)
        let other = workout(at: 86400 + 3600)
        cache.store([old, other], for: week)

        let added = workout(at: 7200)
        cache.store([old, added], for: day1)

        let weekIDs = cache.workouts(in: week)?.map(\.id)
        #expect(weekIDs == [old.id, added.id, other.id], "주 기억에도 새로 조회한 운동이 반영돼야 한다")
    }

    @Test func persistsToFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "workout-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var cache = WorkoutCache()
        let saved = workout(at: 3600)
        cache.store([saved], for: day1)
        cache.save(to: url)

        #expect(WorkoutCache.load(from: url).workouts(in: day1)?.map(\.id) == [saved.id])
    }
}
