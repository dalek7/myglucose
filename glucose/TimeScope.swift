import Foundation

/// 타임라인에서 좌우로 넘길 수 있는 기간 단위.
enum TimeScope: String, CaseIterable, Identifiable {
    case day = "일"
    case week = "주"
    case month = "월"

    var id: Self { self }

    /// 좌우로 넘길 수 있는 페이지 수 (마지막 페이지가 현재 기간).
    var pageCount: Int {
        switch self {
        case .day: return 60
        case .week: return 26
        case .month: return 12
        }
    }

    func interval(forPage index: Int, calendar: Calendar = .current, now: Date = .now) -> DateInterval {
        let stepsBack = pageCount - 1 - index
        switch self {
        case .day:
            let day = calendar.date(byAdding: .day, value: -stepsBack, to: now)!
            let start = calendar.startOfDay(for: day)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .week:
            let ref = calendar.date(byAdding: .weekOfYear, value: -stepsBack, to: now)!
            return calendar.dateInterval(of: .weekOfYear, for: ref)!
        case .month:
            let ref = calendar.date(byAdding: .month, value: -stepsBack, to: now)!
            return calendar.dateInterval(of: .month, for: ref)!
        }
    }

    func title(for interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        switch self {
        case .day:
            formatter.dateFormat = "yyyy년 M월 d일 (E)"
            return formatter.string(from: interval.start)
        case .week:
            formatter.dateFormat = "M월 d일"
            let endFormatter = DateFormatter()
            endFormatter.locale = formatter.locale
            endFormatter.dateFormat = "M월 d일"
            let lastDay = interval.end.addingTimeInterval(-1)
            return "\(formatter.string(from: interval.start)) ~ \(endFormatter.string(from: lastDay))"
        case .month:
            formatter.dateFormat = "yyyy년 M월"
            return formatter.string(from: interval.start)
        }
    }
}
