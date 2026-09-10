import Foundation
import HealthKit
import MeeABridgeCore

@MainActor final class HealthReader {
    private let store = HKHealthStore()
    private let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw BridgeError.healthUnavailable }
        // Completion means the permission sheet finished, not that read access was granted.
        try await store.requestAuthorization(toShare: [], read: [steps])
    }
    func preview() async throws -> StepsSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else { throw BridgeError.healthUnavailable }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let captured = Date()
        let end = calendar.startOfDay(for: captured)
        guard let start = calendar.date(byAdding: .day, value: -7, to: end) else { throw BridgeError.invalidResponse }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKStatisticsCollectionQuery(quantityType: steps, quantitySamplePredicate: predicate,
                                               options: .cumulativeSum, anchorDate: start,
                                               intervalComponents: DateComponents(calendar: calendar, timeZone: calendar.timeZone, day: 1))
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { continuation in
            query.initialResultsHandler = { [store] query, result, _ in
                store.stop(query)
                if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: BridgeError.healthUnavailable) }
            }
            store.execute(query)
        }
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        // HealthKit cumulative statistics merge overlapping sources; do not sum raw phone/watch samples.
        let days = try (0..<7).map { offset throws -> StepsDay in
            let dayStart = calendar.date(byAdding: .day, value: offset, to: start)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let statistics = collection.statistics(for: dayStart)
            if let statistics {
                guard statistics.startDate == dayStart, statistics.endDate == dayEnd else {
                    throw BridgeError.invalidResponse
                }
            }
            let count = statistics?.sumQuantity()?.doubleValue(for: .count())
            return StepsDay(day: format.string(from: dayStart), start: dayStart, end: dayEnd, count: count)
        }
        return try StepsSnapshot(days: days, timeZone: calendar.timeZone.identifier, capturedAt: captured)
    }
}
