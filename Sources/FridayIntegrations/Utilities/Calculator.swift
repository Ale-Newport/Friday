import Foundation

/// A small numeric grammar, never NSExpression, JavaScript, shell, or model arithmetic.
public enum Calculator {
    public enum Failure: Error, Equatable { case invalidExpression, tooComplex, nonFinite }

    public static func evaluate(_ expression: String) throws -> Double {
        guard expression.count <= 2000 else { throw Failure.tooComplex }
        var parser = Parser(expression)
        let value = try parser.expression()
        parser.skipSpace()
        guard parser.index == parser.characters.count else { throw Failure.invalidExpression }
        guard value.isFinite else { throw Failure.nonFinite }
        return value
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var depth = 0
        init(_ value: String) { characters = Array(value.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "pi")) }
        mutating func skipSpace() { while index < characters.count, characters[index].isWhitespace { index += 1 } }
        mutating func take(_ value: Character) -> Bool {
            skipSpace()
            if index < characters.count, characters[index] == value { index += 1; return true }
            return false
        }
        mutating func expression() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.tooComplex }
            var value = try term()
            while true {
                if take("+") { value += try term() }
                else if take("-") { value -= try term() }
                else { return value }
            }
        }
        mutating func term() throws -> Double {
            var value = try unary()
            while true {
                if take("*") { value *= try unary() }
                else if take("/") { value /= try unary() }
                else { return value }
            }
        }
        mutating func unary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.tooComplex }
            if take("+") { return try unary() }
            if take("-") { return -(try unary()) }
            return try power()
        }
        mutating func power() throws -> Double {
            var value = try primary()
            while take("%") { value /= 100 }
            if take("^") { value = pow(value, try unary()) }
            return value
        }
        mutating func primary() throws -> Double {
            if take("(") {
                let value = try expression()
                guard take(")") else { throw Failure.invalidExpression }
                return value
            }
            skipSpace()
            let start = index
            while index < characters.count, characters[index].isLetter || (index > start && characters[index].isNumber) { index += 1 }
            if index > start {
                let name = String(characters[start..<index])
                if name == "pi" { return .pi }
                if name == "e" { return M_E }
                guard take("(") else { throw Failure.invalidExpression }
                var values = [try expression()]
                while take(",") { values.append(try expression()) }
                guard take(")") else { throw Failure.invalidExpression }
                if values.count == 1 {
                    let x = values[0]
                    switch name {
                    case "sqrt": return sqrt(x)
                    case "sin": return sin(x)
                    case "cos": return cos(x)
                    case "tan": return tan(x)
                    case "ln": return log(x)
                    case "log", "log10": return log10(x)
                    case "exp": return exp(x)
                    case "abs": return abs(x)
                    case "floor": return floor(x)
                    case "ceil": return ceil(x)
                    default: break
                    }
                }
                switch name {
                case "sum": return values.reduce(0, +)
                case "mean": return values.reduce(0, +) / Double(values.count)
                case "min": return values.min()!
                case "max": return values.max()!
                default: throw Failure.invalidExpression
                }
            }
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            if index < characters.count, characters[index] == "e" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                while index < characters.count, characters[index].isNumber { index += 1 }
            }
            guard index > start, let value = Double(String(characters[start..<index])) else { throw Failure.invalidExpression }
            return value
        }
    }
}

public enum UnitConversion {
    public enum Failure: Error { case incompatibleUnits }
    private struct Unit { var dimension: String; var factor: Double; var offset: Double = 0 }
    private static let units: [String: Unit] = [
        "m": Unit(dimension: "length", factor: 1), "km": Unit(dimension: "length", factor: 1000),
        "cm": Unit(dimension: "length", factor: 0.01), "mm": Unit(dimension: "length", factor: 0.001),
        "mi": Unit(dimension: "length", factor: 1609.344), "ft": Unit(dimension: "length", factor: 0.3048), "in": Unit(dimension: "length", factor: 0.0254),
        "kg": Unit(dimension: "mass", factor: 1), "g": Unit(dimension: "mass", factor: 0.001), "lb": Unit(dimension: "mass", factor: 0.45359237),
        "oz": Unit(dimension: "mass", factor: 0.028349523125),
        "s": Unit(dimension: "time", factor: 1), "min": Unit(dimension: "time", factor: 60), "h": Unit(dimension: "time", factor: 3600), "day": Unit(dimension: "time", factor: 86400),
        "c": Unit(dimension: "temperature", factor: 1, offset: 273.15), "k": Unit(dimension: "temperature", factor: 1),
        "f": Unit(dimension: "temperature", factor: 5/9, offset: 255.3722222222222),
        "l": Unit(dimension: "volume", factor: 1), "ml": Unit(dimension: "volume", factor: 0.001),
        "m/s": Unit(dimension: "speed", factor: 1), "km/h": Unit(dimension: "speed", factor: 1/3.6), "mph": Unit(dimension: "speed", factor: 0.44704),
        "kn": Unit(dimension: "speed", factor: 1852.0 / 3600),
        // Length
        "yd": Unit(dimension: "length", factor: 0.9144), "nmi": Unit(dimension: "length", factor: 1852),
        // Mass
        "st": Unit(dimension: "mass", factor: 6.35029318), "t": Unit(dimension: "mass", factor: 1000), "mg": Unit(dimension: "mass", factor: 0.000001),
        // Volume (litres; US customary unless marked UK)
        "cl": Unit(dimension: "volume", factor: 0.01), "dl": Unit(dimension: "volume", factor: 0.1), "m3": Unit(dimension: "volume", factor: 1000),
        "gal": Unit(dimension: "volume", factor: 3.785411784), "gal-uk": Unit(dimension: "volume", factor: 4.54609),
        "qt": Unit(dimension: "volume", factor: 0.946352946), "pt": Unit(dimension: "volume", factor: 0.473176473),
        "pt-uk": Unit(dimension: "volume", factor: 0.56826125), "cup": Unit(dimension: "volume", factor: 0.2365882365),
        "floz": Unit(dimension: "volume", factor: 0.0295735295625), "floz-uk": Unit(dimension: "volume", factor: 0.0284130625),
        "tbsp": Unit(dimension: "volume", factor: 0.01478676478125), "tsp": Unit(dimension: "volume", factor: 0.00492892159375),
        // Area (square metres)
        "m2": Unit(dimension: "area", factor: 1), "km2": Unit(dimension: "area", factor: 1_000_000), "cm2": Unit(dimension: "area", factor: 0.0001),
        "ft2": Unit(dimension: "area", factor: 0.09290304), "in2": Unit(dimension: "area", factor: 0.00064516),
        "yd2": Unit(dimension: "area", factor: 0.83612736), "mi2": Unit(dimension: "area", factor: 2_589_988.110336),
        "ha": Unit(dimension: "area", factor: 10_000), "ac": Unit(dimension: "area", factor: 4046.8564224),
        // Fuel economy as distance per volume (km per litre); litres per 100 km is the inverse and is not offered
        "km/l": Unit(dimension: "fuel", factor: 1), "mpg": Unit(dimension: "fuel", factor: 1.609344 / 3.785411784),
        "mpg-uk": Unit(dimension: "fuel", factor: 1.609344 / 4.54609),
    ]
    /// Spoken and written unit names (English and Spanish, singular and plural) → the symbols in `units`, so
    /// "convert 26.2 miles to kilometers" and "pasa 5 kilómetros a millas" work as well as "10 km to mi".
    private static let aliases: [String: String] = {
        let groups: [String: [String]] = [
            "m": ["meter", "meters", "metre", "metres", "metro", "metros"],
            "km": ["kilometer", "kilometers", "kilometre", "kilometres", "kilometro", "kilometros", "kms"],
            "cm": ["centimeter", "centimeters", "centimetre", "centimetres", "centimetro", "centimetros"],
            "mm": ["millimeter", "millimeters", "millimetre", "millimetres", "milimetro", "milimetros"],
            "mi": ["mile", "miles", "milla", "millas"],
            "ft": ["foot", "feet", "pie", "pies"],
            "in": ["inch", "inches", "pulgada", "pulgadas"],
            "kg": ["kilogram", "kilograms", "kilogramo", "kilogramos", "kilo", "kilos", "kgs"],
            "g": ["gram", "grams", "gramo", "gramos"],
            "lb": ["pound", "pounds", "libra", "libras", "lbs"],
            "oz": ["ounce", "ounces", "onza", "onzas"],
            "s": ["second", "seconds", "segundo", "segundos", "sec", "secs"],
            "min": ["minute", "minutes", "minuto", "minutos", "mins"],
            "h": ["hour", "hours", "hora", "horas", "hr", "hrs"],
            "day": ["days", "dia", "dias"],
            "c": ["celsius", "centigrade", "centigrado", "centigrados", "grados celsius"],
            "k": ["kelvin", "kelvins"],
            "f": ["fahrenheit", "grados fahrenheit"],
            "l": ["liter", "liters", "litre", "litres", "litro", "litros"],
            "ml": ["milliliter", "milliliters", "millilitre", "millilitres", "mililitro", "mililitros"],
            "km/h": ["kph", "kmh", "kilometers per hour", "kilometros por hora"],
            "mph": ["miles per hour", "millas por hora"],
            "kn": ["knot", "knots", "nudo", "nudos", "kt"],
            "yd": ["yard", "yards", "yarda", "yardas"],
            "nmi": ["nautical mile", "nautical miles", "milla nautica", "millas nauticas"],
            "st": ["stone", "stones"],
            "t": ["tonne", "tonnes", "metric ton", "metric tons", "tonelada", "toneladas"],
            "mg": ["milligram", "milligrams", "miligramo", "miligramos"],
            "cl": ["centiliter", "centiliters", "centilitre", "centilitres", "centilitro", "centilitros"],
            "dl": ["deciliter", "deciliters", "decilitre", "decilitres", "decilitro", "decilitros"],
            "m3": ["m³", "cubic meter", "cubic meters", "cubic metre", "cubic metres", "metro cubico", "metros cubicos"],
            "gal": ["gallon", "gallons", "us gallon", "us gallons", "galon", "galones"],
            "gal-uk": ["uk gallon", "uk gallons", "imperial gallon", "imperial gallons", "galon imperial", "galones imperiales"],
            "qt": ["quart", "quarts", "cuarto de galon", "cuartos de galon"],
            "pt": ["pint", "pints", "us pint", "us pints", "pinta", "pintas"],
            "pt-uk": ["uk pint", "uk pints", "imperial pint", "imperial pints", "pinta imperial", "pintas imperiales"],
            "cup": ["cups", "taza", "tazas"],
            "floz": ["fl oz", "fluid ounce", "fluid ounces", "onza liquida", "onzas liquidas"],
            "floz-uk": ["uk fluid ounce", "uk fluid ounces", "imperial fluid ounce", "imperial fluid ounces"],
            "tbsp": ["tablespoon", "tablespoons", "cucharada", "cucharadas"],
            "tsp": ["teaspoon", "teaspoons", "cucharadita", "cucharaditas"],
            "m2": ["m²", "sq m", "square meter", "square meters", "square metre", "square metres", "metro cuadrado", "metros cuadrados"],
            "km2": ["km²", "sq km", "square kilometer", "square kilometers", "square kilometre", "square kilometres", "kilometro cuadrado", "kilometros cuadrados"],
            "cm2": ["cm²", "square centimeter", "square centimeters", "square centimetre", "square centimetres", "centimetro cuadrado", "centimetros cuadrados"],
            "ft2": ["ft²", "sq ft", "square foot", "square feet", "pie cuadrado", "pies cuadrados"],
            "in2": ["in²", "sq in", "square inch", "square inches", "pulgada cuadrada", "pulgadas cuadradas"],
            "yd2": ["yd²", "sq yd", "square yard", "square yards", "yarda cuadrada", "yardas cuadradas"],
            "mi2": ["mi²", "sq mi", "square mile", "square miles", "milla cuadrada", "millas cuadradas"],
            "ha": ["hectare", "hectares", "hectarea", "hectareas"],
            "ac": ["acre", "acres"],
            "km/l": ["kmpl", "kilometers per liter", "kilometres per litre", "kilometros por litro"],
            "mpg": ["miles per gallon", "us mpg", "millas por galon"],
            "mpg-uk": ["uk mpg", "imperial mpg", "miles per imperial gallon"],
        ]
        var table: [String: String] = [:]
        for (symbol, names) in groups { for name in names { table[name] = symbol } }
        return table
    }()

    static func symbol(for unit: String) -> String {
        let cleaned = unit.lowercased().replacingOccurrences(of: "°", with: "").replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if units[cleaned] != nil { return cleaned }
        if let alias = aliases[cleaned] { return alias }
        // Accents are optional ("kilómetros", "galón", "hectárea"); superscripts ("m²") are kept by the table above.
        let folded = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return units[folded] != nil ? folded : aliases[folded] ?? folded
    }

    public static func convert(_ value: Double, from: String, to: String) throws -> Double {
        guard let a = units[symbol(for: from)], let b = units[symbol(for: to)], a.dimension == b.dimension else { throw Failure.incompatibleUnits }
        let result = (value * a.factor + a.offset - b.offset) / b.factor
        guard result.isFinite else { throw Calculator.Failure.nonFinite }
        return result
    }
}
