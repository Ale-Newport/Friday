import Foundation
import FridayCore

public struct UtilitiesIntegration: AppIntegration {
    public let id: IntegrationID = "utilities"
    public let displayName = LocalizedText(en: "Utilities", es: "Utilidades")
    public let summary = LocalizedText(
        en: "Verified local calculations, unit conversions and date differences.",
        es: "Cálculos locales, conversiones de unidades y diferencias entre fechas.")
    public let symbolName = "function"
    public let permissionRequirements: [PermissionRequirement] = []
    let currencyRates: WeatherCache
    public init(currencyRates: WeatherCache = WeatherCache()) { self.currencyRates = currencyRates }
    public var tools: [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "utilities.calculate", integration: id, title: "Calculate",
                summary:
                    "Evaluates numeric expressions: + - * / ^ %, parentheses, pi/e, sqrt, sin/cos/tan (radians), ln/log, exp, abs, floor/ceil, sum/mean/min/max. Decimal dot; comma separates arguments. No symbolic algebra.",
                parameters: [.string("expression", "Numeric expression.", required: true, maxLength: 2000)],
                safety: .readOnly),
            ToolDescriptor(
                name: "utilities.convert", integration: id, title: "Convert units",
                summary:
                    "Converts compatible length, mass, time, temperature, volume, area, speed or fuel-economy units. No currency conversion.",
                parameters: [
                    .number("value", "Value.", required: true),
                    .string(
                        "from",
                        "Unit symbol or name in English or Spanish: m,km,cm,mm,mi,yd,ft,in,nmi; kg,g,mg,lb,oz,st,t; s,min,h,day; C,F,K; l,ml,cl,dl,m3,gal,gal-uk,qt,pt,pt-uk,cup,floz,tbsp,tsp; m2,km2,cm2,ft2,in2,yd2,mi2,ha,ac; m/s,km/h,mph,kn; km/l,mpg,mpg-uk.",
                        required: true, maxLength: 40), .string("to", "Target unit.", required: true, maxLength: 40),
                ], safety: .readOnly),
            ToolDescriptor(
                name: "utilities.date_difference", integration: id, title: "Date difference",
                summary: "Elapsed seconds and calendar days between two ISO dates in the user's timezone.",
                parameters: [
                    .dateOrDateTime("from", "Start.", required: true), .dateOrDateTime("to", "End.", required: true),
                ], safety: .readOnly),
        ] + advancedTools
    }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        do {
            if !["utilities.calculate", "utilities.convert", "utilities.date_difference"].contains(
                call.descriptor.name.rawValue)
            {
                return try await advanced(call, context: context)
            }
            let value: Double
            var data: JSONObject = [:]
            switch call.descriptor.name.rawValue {
            case "utilities.calculate": value = try Calculator.evaluate(call.string("expression") ?? "")
            case "utilities.convert":
                value = try UnitConversion.convert(
                    call.arguments["value"]?.doubleValue ?? 0, from: call.string("from") ?? "",
                    to: call.string("to") ?? "")
                data["unit"] = call.arguments["to"]
            case "utilities.date_difference":
                guard let start = ISODates.date(from: call.string("from") ?? "", timeZone: context.timeZone) else {
                    throw JarvisError.invalidArgument(
                        parameter: "from",
                        LocalizedText(
                            en: "'from' must be an ISO 8601 date or date-time.",
                            es: "«from» debe ser una fecha o fecha y hora ISO 8601."))
                }
                guard let end = ISODates.date(from: call.string("to") ?? "", timeZone: context.timeZone) else {
                    throw JarvisError.invalidArgument(
                        parameter: "to",
                        LocalizedText(
                            en: "'to' must be an ISO 8601 date or date-time.",
                            es: "«to» debe ser una fecha o fecha y hora ISO 8601."))
                }
                value = end.timeIntervalSince(start)
                data["calendar_days"] = .int(
                    context.calendar.dateComponents(
                        [.day], from: context.calendar.startOfDay(for: start), to: context.calendar.startOfDay(for: end)
                    ).day ?? 0)
                data["unit"] = "seconds"
            default: throw Calculator.Failure.invalidExpression
            }
            data["value"] = .double(value)
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: context.language == .es ? "es_ES" : "en_GB")
            if call.descriptor.name.rawValue == "utilities.convert" {
                formatter.numberStyle = .decimal   // "43,560 square feet", "20.000 metros cuadrados"
                // Conversions are said aloud: two decimals ("42.16 kilometers"), or three significant digits below 1
                // ("0.0254 m"). The exact value stays in `data["value"]` for tools that use the result (#1).
                if Swift.abs(value) >= 1 || value == 0 {
                    formatter.maximumFractionDigits = 2
                } else {
                    formatter.usesSignificantDigits = true
                    formatter.maximumSignificantDigits = 3
                }
            } else {
                formatter.maximumFractionDigits = 10
            }
            let formatted = formatter.string(from: NSNumber(value: value)) ?? String(value)
            return .done(
                ToolOutput(
                    message: formatted + (data["unit"]?.stringValue.map { " " + $0 } ?? ""), data: .object(data),
                    verification: .verified(context.language.pick("Calculated locally.", "Calculado localmente."))))
        } catch let error as JarvisError { throw error } catch is CancellationError { throw CancellationError() } catch
        {
            throw JarvisError.failed(
                "calculation_failed",
                en:
                    "I couldn't calculate that expression or conversion. Check the numbers, units and supported functions.",
                es:
                    "No pude calcular esa expresión o conversión. Revisa los números, las unidades y las funciones compatibles."
            )
        }
    }
}
