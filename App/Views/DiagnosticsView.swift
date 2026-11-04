import FridayAssistant
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(model.t("Wake word", "Palabra de activación")) {
                VStack(alignment: .leading) {
                    Text(model.wakeStatusText)
                    if let engine = model.wake.engine { Text("\(engine.displayName) · sensitivity \(String(format: "%.2f", engine.sensitivity))").font(.caption).foregroundStyle(.secondary) }
                    if let capture = model.wake.capture { Text("\(capture.deviceName) · \(Int(capture.sampleRate)) Hz").font(.caption).foregroundStyle(.secondary) }
                    Text(model.t("Microphone level: \(String(format: "%.0f", model.composition.recorder.lastLevelDecibels)) dBFS", "Nivel del micrófono: \(String(format: "%.0f", model.composition.recorder.lastLevelDecibels)) dBFS")).font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(model.t("Latency of the last requests (ms)", "Latencia de las últimas peticiones (ms)")) {
                Table(model.latencyHistory.reversed()) {
                    TableColumn(model.t("Path", "Vía")) { Text($0.path ?? "—") }
                    TableColumn(model.t("Wake→listen", "Activación→escucha")) { Text($0.wakeToListenMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Speech end→text", "Fin habla→texto")) { Text($0.speechEndToTranscriptMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Routing", "Enrutado")) { Text($0.routingMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Model", "Modelo")) { Text($0.planningMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Tools", "Herramientas")) { Text($0.toolsMs.map(String.init) ?? "—") }
                    TableColumn("Total") { Text($0.totalMs.map(String.init) ?? "—") }
                    TableColumn(model.t("Provider", "Proveedor")) { Text(($0.provider ?? "—") + " " + ($0.model ?? "")) }
                }
                .frame(minHeight: 180)
            }
            GroupBox(model.t("Sidecar log", "Registro del proceso auxiliar")) {
                SidecarLogView()
            }
            Spacer()
        }
        .padding(16)
    }
}

extension LatencyReport: Identifiable {
    public var id: String { "\(totalMs ?? 0)-\(path ?? "")-\(planningMs ?? 0)-\(routingMs ?? 0)" }
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
