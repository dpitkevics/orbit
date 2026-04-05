import Foundation

/// A parsed cron field value.
public enum CronField: Sendable, Equatable {
    /// Match any value.
    case any
    /// Match a specific value.
    case value(Int)
    /// Match values at a step interval (e.g., */15).
    case step(Int)
    /// Match values in a range (e.g., 9-17).
    case range(Int, Int)
    /// Match any value in a list (e.g., 1,3,5).
    case list([Int])

    /// Check if this field matches a given value.
    public func matches(_ val: Int) -> Bool {
        switch self {
        case .any:
            return true
        case .value(let v):
            return val == v
        case .step(let s):
            return s > 0 && val % s == 0
        case .range(let lo, let hi):
            return val >= lo && val <= hi
        case .list(let values):
            return values.contains(val)
        }
    }
}

/// Standard 5-field cron expression: minute hour day-of-month month day-of-week.
public struct CronExpression: Sendable {
    public let minute: CronField
    public let hour: CronField
    public let dayOfMonth: CronField
    public let month: CronField
    public let dayOfWeek: CronField
    public let raw: String

    public init(_ expression: String) throws {
        let fields = expression.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count == 5 else {
            throw CronParseError.invalidFieldCount(got: fields.count, expected: 5)
        }

        self.raw = expression
        self.minute = try Self.parseField(String(fields[0]))
        self.hour = try Self.parseField(String(fields[1]))
        self.dayOfMonth = try Self.parseField(String(fields[2]))
        self.month = try Self.parseField(String(fields[3]))
        self.dayOfWeek = try Self.parseField(String(fields[4]))
    }

    /// Check if this cron expression matches the given date components.
    /// Uses Calendar weekday convention: Sunday=1, Monday=2, etc.
    /// Cron convention: Sunday=0 (or 7), Monday=1, etc.
    public func matches(_ components: DateComponents) -> Bool {
        guard let minute = components.minute,
              let hour = components.hour,
              let day = components.day,
              let month = components.month,
              let weekday = components.weekday else {
            return false
        }

        // Convert Calendar weekday (Sun=1) to cron weekday (Sun=0)
        let cronWeekday = weekday - 1

        return self.minute.matches(minute)
            && self.hour.matches(hour)
            && self.dayOfMonth.matches(day)
            && self.month.matches(month)
            && self.dayOfWeek.matches(cronWeekday)
    }

    /// Check if this expression matches the current time.
    public func matchesNow() -> Bool {
        let components = Calendar.current.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: Date()
        )
        return matches(components)
    }

    // MARK: - Parsing

    private static func parseField(_ field: String) throws -> CronField {
        if field == "*" {
            return .any
        }

        // Step: */N
        if field.hasPrefix("*/") {
            let stepStr = String(field.dropFirst(2))
            guard let step = Int(stepStr), step > 0 else {
                throw CronParseError.invalidField(field)
            }
            return .step(step)
        }

        // Range: N-M
        if field.contains("-"), !field.contains(",") {
            let parts = field.split(separator: "-")
            guard parts.count == 2,
                  let lo = Int(parts[0]),
                  let hi = Int(parts[1]),
                  lo <= hi else {
                throw CronParseError.invalidField(field)
            }
            return .range(lo, hi)
        }

        // List: N,M,O
        if field.contains(",") {
            let values = try field.split(separator: ",").map { part -> Int in
                guard let v = Int(part) else {
                    throw CronParseError.invalidField(field)
                }
                return v
            }
            return .list(values)
        }

        // Single value
        guard let value = Int(field) else {
            throw CronParseError.invalidField(field)
        }
        return .value(value)
    }
}

public enum CronParseError: Error, LocalizedError {
    case invalidFieldCount(got: Int, expected: Int)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFieldCount(let got, let expected):
            return "Cron expression has \(got) fields, expected \(expected)."
        case .invalidField(let field):
            return "Invalid cron field: '\(field)'."
        }
    }
}
