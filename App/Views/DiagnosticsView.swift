import FridayAssistant
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var microphoneLevel: Float = -120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(model.t("Wake word", "Palabra de activación")) {
                VStack(alignment: .leading) {
                    Text(model.wakeStatusText)
                    if let engine = model.wake.engine { Text("\(engine.displayName) · sensitivity \(String(format: "%.2f", engine.sensitivity))").font(.caption).foregroundStyle(.secondary) }
                    if let capture = model.wake.capture { Text("\(capture.deviceName) · \(Int(capture.sampleRate)) Hz").font(.caption).foregroundStyle(.secondary) }
                    Text(model.t("Microphone level: \(String(format: "%.0f", microphoneLevel)) dBFS", "Nivel del micrófono: \(String(format: "%.0f", microphoneLevel)) dBFS")).font(.caption).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(model.t("Latency of the last requests (ms)", "Latencia de las últimas peticiones (ms)")) {
                Table(model.latencyHistory.reversed()) {
                    TableColumn(model.t("Path", "Vía")) { Text($0.report.path ?? "—") }
                    TableColumn(model.t("Wake→listen", "Activación→escucha")) { Text($0.report.wakeToListenMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Speech end→text", "Fin habla→texto")) { Text($0.report.speechEndToTranscriptMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Routing", "Enrutado")) { Text($0.report.routingMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Model", "Modelo")) { Text($0.report.planningMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Tools", "Herramientas")) { Text($0.report.toolsMs.map(String.init) ?? "—") }
                    TableColumn("Total") { Text($0.report.totalMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Provider", "Proveedor")) { Text(($0.report.provider ?? "—") + " " + ($0.report.model ?? "")) }
                }
                .frame(minHeight: 180)
            }
            GroupBox(model.t("Sidecar log", "Registro del proceso auxiliar")) {
                SidecarLogView()
            }
            Spacer()
        }
        .padding(16)
        .task {
            // The recorder's level is a plain property, not observable: sample it while the window is open.
            let recorder = model.composition.recorder
            while !Task.isCancelled {
                microphoneLevel = recorder.lastLevelDecibels
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

struct SidecarLogView: View {
    @Environment(AppModel.self) private var model
    @State private var lines: [String] = []
    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(minHeight: 120)
        .task {
            while !Task.isCancelled {
                if let sidecar = model.composition.sidecar { lines = await sidecar.recentLog(lines: 30) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
