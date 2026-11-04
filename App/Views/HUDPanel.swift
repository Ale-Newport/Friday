// The floating assistant panel; adapted from the wake-word project's ActivationHUD (same author).
import AppKit
import FridayAssistant
import Observation
import SwiftUI

/// A discreet panel near the top of the screen: listening state, live transcript, the answer, task progress and
/// the buttons of a pending question. It never steals keyboard focus; it accepts clicks only while a question
/// is pending.
@MainActor
final class AssistantHUDController {
    private let model: AppModel
    private let hudModel = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func update(for snapshot: AssistantSnapshot) {
        hudModel.phase = snapshot.phase
        hudModel.pending = snapshot.pending
        hudModel.steps = snapshot.currentSteps
        hudModel.browserLine = snapshot.browserStatusLine
        if let last = snapshot.transcript.last(where: { $0.role == .assistant }) { hudModel.answer = last.text }
        if let user = snapshot.transcript.last(where: { $0.role == .user }) { hudModel.request = user.text }
        let visible = snapshot.phase.isBusy || snapshot.pending != nil || snapshot.inConversation
        if visible { show() } else if hudModel.isVisible { hideSoon() }
        panel?.ignoresMouseEvents = snapshot.pending == nil
    }

    func hideImmediately() {
        hideTask?.cancel()
        hudModel.isVisible = false
        panel?.orderOut(nil)
    }

    private func show() {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !hudModel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
            hudModel.isVisible = true
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Friday is listening", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func hideSoon() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))   // leave the answer readable
            guard !Task.isCancelled, let self else { return }
            self.hudModel.isVisible = false
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AssistantHUDView(model: hudModel, app: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height + 6))
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class HUDModel {
    var isVisible = false
    var phase: AssistantPhase = .idle
    var request = ""
    var answer = ""
    var steps: [String] = []
    var pending: PendingPrompt?
    var browserLine: String?
}

struct AssistantHUDView: View {
    var model: HUDModel
    var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: String {
        switch model.phase {
        case .idle: return app.t("Done", "Hecho")
        case .listening(let partial): return partial.isEmpty ? app.t("Listening…", "Escuchando…") : partial
        case .thinking: return app.t("Thinking…", "Pensando…")
        case .acting(let step): return step
        case .speaking: return app.t("Speaking", "Hablando")
        case .waiting(let question): return question
        case .error(let message): return message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FridayOrb(animated: !reduceMotion, phase: model.phase).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Friday").font(.system(.headline, design: .rounded, weight: .semibold))
                    Text(headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: headline)
                }
                Spacer(minLength: 0)
            }
            if case .speaking(let text) = model.phase, !text.isEmpty {
                Text(text).font(.body).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            } else if case .idle = model.phase, !model.answer.isEmpty {
                Text(model.answer).font(.body).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }
            if !model.steps.isEmpty, case .acting = model.phase {
                HStack(spacing: 6) {
                    ForEach(model.steps.prefix(4), id: \.self) { step in
                        Text(step).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.quaternary))
                    }
                }
            }
            if let line = model.browserLine { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let pending = model.pending {
                HStack(spacing: 8) {
                    switch pending.kind {
                    case .clarification where !pending.options.isEmpty:
                        ForEach(Array(pending.options.enumerated()), id: \.offset) { index, option in
                            Button(option) { app.answer(pending, index: index, approve: nil) }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Button(app.t("Cancel", "Cancelar")) { app.answer(pending, index: nil, approve: false) }.buttonStyle(.borderless).controlSize(.small)
                    case .browserManual:
                        Button(app.t("Done", "Listo")) { app.answer(pending, index: nil, approve: true) }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button(app.t("Cancel", "Cancelar")) { app.answer(pending, index: nil, approve: false) }.buttonStyle(.bordered).controlSize(.small)
                    default:
                        Button(app.t("Confirm", "Confirmar")) { app.answer(pending, index: nil, approve: true) }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button(app.t("Cancel", "Cancelar")) { app.answer(pending, index: nil, approve: false) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 480, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial) }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.28), radius: 18, y: 8) }
        .scaleEffect(model.isVisible ? 1 : 0.9, anchor: .top)
        .opacity(model.isVisible ? 1 : 0)
        .offset(y: model.isVisible ? 0 : -14)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.25), value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
    }
}

/// The orb: cyan while listening, violet while thinking, green while acting, warm while speaking.
struct FridayOrb: View {
    var animated = true
    var phase: AssistantPhase = .idle

    private var tint: Color {
        switch phase {
        case .listening: return .cyan
        case .thinking: return .purple
        case .acting: return .green
        case .speaking: return .orange
        case .waiting: return .yellow
        case .error: return .red
        case .idle: return .cyan
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let p = (t * 0.9 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(tint.opacity((1 - p) * 0.5), lineWidth: 1.5).scaleEffect(0.55 + p * 0.55)
                }
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), tint, tint.opacity(0.6)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 22))
                    .scaleEffect(0.52 + 0.04 * sin(t * 4))
                    .shadow(color: tint.opacity(0.7), radius: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
