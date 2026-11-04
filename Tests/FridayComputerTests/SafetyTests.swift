import Foundation
import Testing

@testable import FridayComputer

@Suite struct SafetyTests {
    @Test(arguments: [
        "Delete", "Remove", "Purchase", "Pay now", "Send", "Erase", "Format Disk", "Empty Trash", "Move to Trash", "Log Out", "Unsubscribe",
        "Eliminar", "Borrar todo", "Comprar ahora", "Pagar", "Enviar", "Suprimir", "Quitar", "Vaciar papelera", "Formatear", "Cerrar sesión", "Publicar",
    ])
    func flagsRiskyLabels(label: String) {
        #expect(Safety.riskyLabel(label))
    }

    @Test(arguments: ["Save", "Cancel", "Open", "Guardar", "Cancelar", "Abrir", "Apply changes", "Back", "Atrás", "Close", "Cerrar"])
    func allowsOrdinaryLabels(label: String) {
        #expect(!Safety.riskyLabel(label))
    }

    @Test(arguments: ["OK", "Yes", "Continue", "Aceptar", "Sí", "Continuar"])
    func genericConfirmationsAreRiskyWithoutContext(label: String) {
        // Without the dialog text there is no way to prove a generic confirmation is harmless (menu replays).
        #expect(Safety.riskyLabel(label))
        #expect(!Safety.riskyLabel(label, context: "Document saved."))
    }

    @Test func genericConfirmationsAreRiskyOnlyInRiskyContext() {
        #expect(Safety.riskyLabel("OK", context: "Delete 3 items? This cannot be undone."))
        #expect(Safety.riskyLabel("Aceptar", context: "¿Eliminar 3 elementos?"))
        #expect(Safety.riskyLabel("Yes", context: "Purchase for $9.99?"))
        #expect(!Safety.riskyLabel("OK", context: "Document saved."))
        #expect(!Safety.riskyLabel("Cancel", context: "Delete 3 items?"))
        #expect(!Safety.riskyLabel("Cancelar", context: "¿Eliminar 3 elementos?"))
    }

    @Test func detectsSecretLabels() {
        for label in ["Password", "Passcode", "Card number", "CVV", "API key", "Token", "Contraseña", "Clave", "Tarjeta", "Código de verificación", "IBAN"] {
            #expect(Safety.secret(label), "\(label)")
        }
        for label in ["Name", "Email", "Search", "Nombre", "Buscar", "Title"] {
            #expect(!Safety.secret(label), "\(label)")
        }
    }

    @Test func masksCardNumbersAndCodes() {
        #expect(Safety.mask("Card 4111 1111 1111 1111 on file") == "Card [SECRET] on file")
        #expect(Safety.mask("SSN 123-45-6789") == "SSN [SECRET]")
        #expect(Safety.mask("Your verification code is 482913") == "Your verification code is [SECRET]")
        #expect(Safety.mask("Tu código es 4829") == "Tu código es [SECRET]")
        #expect(Safety.mask("Order 42 shipped on 2026") == "Order 42 shipped on 2026")
    }

    @Test func normalisesAndRanks() {
        #expect(Safety.normalized("  Wi\u{2011}Fi   Settings… ") == "wi-fi settings...")
        #expect(Safety.normalized("Guardar Como…") == "guardar como...")
        #expect(Safety.rank("Save As…", "save as…") == 4)
        #expect(Safety.rank("Save As…", "save") == 3)
        #expect(Safety.rank("Open Recent File", "recent") == 2)
        #expect(Safety.rank("Preferences", "fer") == 1)
        #expect(Safety.rank("Preferences", "zzz") == 0)
        #expect(Safety.rank("Visualización", "visualizacion") == 4)
    }
}
