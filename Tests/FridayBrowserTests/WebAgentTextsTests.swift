import Foundation
import Testing
import FridayCore
@testable import FridayBrowser

/// Every text the user reads or hears about a browser task exists in English and Spanish and says Friday.
@Suite struct WebAgentTextsTests {
    @Test func approvalQuestionsCoverEveryKindInBothLanguages() {
        let click: JSONValue = ["label": "Place order", "host": "shop.test", "url": "https://shop.test/checkout", "title": "Checkout"]
        for kind in ["payment", "purchase", "destructive", "account", "send", "sensitive", "weird"] {
            let en = WebAgentTexts.approvalQuestion(kind: kind, data: click, language: .en)
            let es = WebAgentTexts.approvalQuestion(kind: kind, data: click, language: .es)
            #expect(en.hasPrefix("Friday is about to click “Place order” on shop.test"), "\(kind): \(en)")
            #expect(es.hasPrefix("Friday va a pulsar «Place order» en shop.test"), "\(kind): \(es)")
            #expect(en != es && !en.contains("Jarvis") && !es.contains("Jarvis"))
        }
        #expect(WebAgentTexts.approvalQuestion(kind: "payment", data: click, language: .en).hasSuffix("which may spend money or submit a payment."))
        #expect(WebAgentTexts.approvalQuestion(kind: "destructive", data: click, language: .es).hasSuffix("lo que puede borrar o cancelar algo."))
        #expect(WebAgentTexts.approvalDetail(kind: "payment", data: click, language: .es) == "Página: Checkout — https://shop.test/checkout")
    }

    @Test func downloadsAndUploadsNameTheFileAndThePlace() {
        let download: JSONValue = ["name": "report.pdf", "url": "https://files.test/report.pdf", "folder": "/Users/me/Downloads/Friday", "host": "files.test"]
        #expect(WebAgentTexts.approvalQuestion(kind: "download", data: download, language: .en) == "Friday wants to save “report.pdf” from files.test to /Users/me/Downloads/Friday.")
        #expect(WebAgentTexts.approvalQuestion(kind: "download", data: download, language: .es) == "Friday quiere guardar «report.pdf» de files.test en /Users/me/Downloads/Friday.")
        #expect(WebAgentTexts.approvalDetail(kind: "download", data: download, language: .en) == "https://files.test/report.pdf")
        let upload: JSONValue = ["name": "cv.pdf", "path": "/Users/me/Downloads/Friday/cv.pdf", "size": 2048, "host": "jobs.test", "field": "Résumé"]
        #expect(WebAgentTexts.approvalQuestion(kind: "upload", data: upload, language: .en) == "Friday is about to upload “cv.pdf” to jobs.test (field: Résumé).")
        #expect(WebAgentTexts.approvalQuestion(kind: "upload", data: upload, language: .es) == "Friday va a subir «cv.pdf» a jobs.test (campo: Résumé).")
        #expect(WebAgentTexts.approvalDetail(kind: "upload", data: upload, language: .en)?.hasPrefix("/Users/me/Downloads/Friday/cv.pdf · 2") == true)
    }

    @Test func legacyQuestionsAreRebrandedWhenNoFactsExist() {
        let legacy: JSONValue = ["question": "Jarvis is about to click \"Buy\" on x.test."]
        #expect(WebAgentTexts.approvalQuestion(kind: "sensitive", data: legacy, language: .en) == "Friday is about to click \"Buy\" on x.test.")
        #expect(WebAgentTexts.approvalQuestion(kind: "sensitive", data: .null, language: .es) == "Friday necesita tu aprobación para continuar.")
        #expect(WebAgentTexts.approvalDetail(kind: "sensitive", data: ["detail": "Page: x"], language: .en) == "Page: x")
    }

    @Test func manualMessagesTellTheUserHowToContinue() {
        #expect(WebAgentTexts.manualMessage(kind: "captcha", message: "This page shows a CAPTCHA.", host: "google.com", language: .en)
                == "google.com is asking you to prove you are human. Solve it in Chrome, then say or press Done.")
        #expect(WebAgentTexts.manualMessage(kind: "captcha", message: "", host: nil, language: .es)
                == "El sitio te pide demostrar que eres humano. Resuélvelo en Chrome y luego di o pulsa Listo.")
        #expect(WebAgentTexts.manualMessage(kind: "login", message: "", host: "bank.test", language: .es)
                == "bank.test necesita que inicies sesión. Inicia sesión en Chrome y luego di o pulsa Listo.")
        #expect(WebAgentTexts.manualMessage(kind: "manual", message: "Jarvis needs the 2FA code.", host: nil, language: .en)
                == "Friday needs the 2FA code. Finish it in Chrome, then say or press Done.")
        #expect(WebAgentTexts.manualMessage(kind: "manual", message: "", host: nil, language: .es)
                == "Friday necesita que termines un paso en Chrome. Luego di o pulsa Listo.")
        // The Assistant speaks the prompt in the language it detects in the text: the Spanish text must read as Spanish.
        #expect(LanguageDetector.detect(WebAgentTexts.manualMessage(kind: "captcha", message: "", host: "x.es", language: .es)) == .es)
        #expect(LanguageDetector.detect(WebAgentTexts.manualMessage(kind: "login", message: "", host: "x.test", language: .en)) == .en)
    }

    @Test func chromeErrorCodesAreLocalisedAndUnknownOnesKeepTheirText() {
        for code in ["chrome_not_found", "not_chrome", "profile_in_use", "chrome_exited", "devtools_timeout", "chrome_not_running", "remote_debugging_off",
                     "chrome_disconnected", "chrome_not_connected", "task_lost", "sidecar_unreachable"] {
            let en = WebAgentTexts.chromeError(code: code, fallback: nil, language: .en)
            let es = WebAgentTexts.chromeError(code: code, fallback: nil, language: .es)
            #expect(!en.isEmpty && !es.isEmpty && en != es, Comment(rawValue: code))
            #expect(!en.contains("Jarvis") && !es.contains("Jarvis"), Comment(rawValue: code))
        }
        #expect(WebAgentTexts.chromeError(code: "profile_in_use", fallback: "The Jarvis automation profile…", language: .es).hasPrefix("El perfil de Chrome de Friday"))
        #expect(WebAgentTexts.chromeError(code: "llm_error", fallback: "HTTP 401", language: .es) == "El modelo de texto falló: HTTP 401")
        #expect(WebAgentTexts.chromeError(code: nil, fallback: "Close the Jarvis Chrome window.", language: .en) == "Close the Friday Chrome window.")
        #expect(WebAgentTexts.chromeError(code: "budget_exceeded", fallback: "Se agotó el tiempo máximo de 10 minutos.", language: .es) == "Se agotó el tiempo máximo de 10 minutos.")
        #expect(WebAgentTexts.chromeError(code: nil, fallback: "  ", language: .es) == "Error desconocido.")
    }
}
