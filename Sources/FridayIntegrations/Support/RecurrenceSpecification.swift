import EventKit
import Foundation
import FridayCore

struct RecurrenceSpecification: Sendable, Hashable {
    var frequency: String
    var interval: Int = 1
    /// ISO weekdays, Monday=1 … Sunday=7.
    var weekdays: [Int] = []
    var until: Date?
    var count: Int?
    var rule: EKRecurrenceRule {
        let f: EKRecurrenceFrequency =
            frequency == "daily"
            ? .daily : frequency == "monthly" ? .monthly : frequency == "yearly" ? .yearly : .weekly
        let end = count.map { EKRecurrenceEnd(occurrenceCount: $0) } ?? until.map { EKRecurrenceEnd(end: $0) }
        let days = weekdays.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0 == 7 ? 1 : $0 + 1)!) }
        return EKRecurrenceRule(
            recurrenceWith: f, interval: interval, daysOfTheWeek: days.isEmpty ? nil : days, daysOfTheMonth: nil,
            monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }
    init(frequency: String, interval: Int = 1, weekdays: [Int] = [], until: Date? = nil, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.until = until
        self.count = count
    }
    init(rule: EKRecurrenceRule) {
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        default: frequency = "weekly"
        }
        interval = rule.interval
        weekdays = (rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue == 1 ? 7 : $0.dayOfTheWeek.rawValue - 1 }
            .sorted()
        until = rule.recurrenceEnd?.endDate
        count = rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil }
    }
    func json(zone: TimeZone) -> JSONValue {
        [
            "frequency": .string(frequency), "interval": .int(interval),
            "iso_weekdays": .array(weekdays.map(JSONValue.int)),
            "until": until.map { .string(ISODates.string(from: $0, timeZone: zone)) } ?? .null,
            "count": count.map(JSONValue.int) ?? .null,
        ]
    }
    static func parameters(prefix: String = "") -> [ToolParameter] {
        [
            .integer(prefix + "repeat_interval", "Every N recurrence periods.", min: 1, max: 365, default: 1),
            .strings(
                prefix + "repeat_weekdays", "Weekday codes mon,tue,wed,thu,fri,sat,sun (full English or Spanish names also accepted); weekly recurrence only.",
                maxItems: 7, maxLength: 12),
            .dateTime(prefix + "repeat_until", "Last recurrence date-time; mutually exclusive with repeat_count."),
            .integer(prefix + "repeat_count", "Maximum occurrences including the first.", min: 1, max: 1000),
        ]
    }
    static func parse(
        _ call: ValidatedToolCall, frequencyKey: String = "recurrence", prefix: String = "", context: ExecutionContext
    ) throws -> Self? {
        guard let frequency = call.string(frequencyKey), frequency != "none" else {
            guard call.strings(prefix + "repeat_weekdays").isEmpty,
                !call.has(prefix + "repeat_until"), !call.has(prefix + "repeat_count"),
                (call.int(prefix + "repeat_interval") ?? 1) == 1
            else {
                throw integrationFailure(
                    "recurrence_frequency", "Specify the recurrence frequency with repeat options.",
                    "Indica la frecuencia de repetición junto con sus opciones.")
            }
            return nil
        }
        var days: [Int] = []
        for value in call.strings(prefix + "repeat_weekdays") {
            guard let day = Self.weekday(named: value) else {
                throw JarvisError.invalidArgument(
                    parameter: prefix + "repeat_weekdays",
                    LocalizedText(
                        en: "'\(value)' is not a weekday; use mon, tue, wed, thu, fri, sat or sun.",
                        es: "«\(value)» no es un día de la semana; usa mon, tue, wed, thu, fri, sat o sun."))
            }
            days.append(day)
        }
        if frequency == "weekdays" { days = [1, 2, 3, 4, 5] }
        if frequency == "weekends" { days = [6, 7] }
        guard days.isEmpty || ["weekly", "weekdays", "weekends"].contains(frequency) else {
            throw JarvisError.invalidArgument(
                parameter: prefix + "repeat_weekdays",
                LocalizedText(
                    en: "repeat_weekdays only applies to a weekly recurrence, not to '\(frequency)'.",
                    es: "repeat_weekdays solo se aplica a una repetición semanal, no a «\(frequency)»."))
        }
        guard !(call.has(prefix + "repeat_until") && call.has(prefix + "repeat_count")) else {
            throw JarvisError.invalidArgument(
                parameter: prefix + "repeat_until",
                LocalizedText(
                    en: "Give either repeat_until or repeat_count, not both.",
                    es: "Indica repeat_until o repeat_count, pero no ambos."))
        }
        let until = call.string(prefix + "repeat_until").flatMap { ISODates.date(from: $0, timeZone: context.timeZone) }
        let first = ["due", "new_due", "start", "new_start"].compactMap { call.string($0) }.compactMap {
            ISODates.date(from: $0, timeZone: context.timeZone)
        }.first
        if let first, let until, until < first {
            throw integrationFailure(
                "recurrence_end", "Recurrence must end on or after its first date.",
                "La repetición debe finalizar en su primera fecha o después.")
        }
        return Self(
            frequency: ["weekdays", "weekends"].contains(frequency) ? "weekly" : frequency,
            interval: call.int(prefix + "repeat_interval") ?? 1, weekdays: Array(Set(days)).sorted(), until: until,
            count: call.int(prefix + "repeat_count"))
    }
    var simpleName: String { weekdays == [1, 2, 3, 4, 5] ? "weekdays" : weekdays == [6, 7] ? "weekends" : frequency }

    /// ISO weekday (Monday = 1) for a three-letter code or a full English/Spanish name, accent-insensitive.
    static func weekday(named value: String) -> Int? {
        let key = TextFolding.fold(value.trimmingCharacters(in: .whitespacesAndNewlines))
        let names: [String: Int] = [
            "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6, "sun": 7,
            "monday": 1, "tuesday": 2, "wednesday": 3, "thursday": 4, "friday": 5, "saturday": 6, "sunday": 7,
            "lun": 1, "mar": 2, "mie": 3, "jue": 4, "vie": 5, "sab": 6, "dom": 7,
            "lunes": 1, "martes": 2, "miercoles": 3, "jueves": 4, "viernes": 5, "sabado": 6, "domingo": 7,
        ]
        return names[key]
    }
}
