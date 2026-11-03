import SwiftUI

/// One line above the box: a pulsing dot, a label, the run's step chip, the answers as segments
/// (ai.js tkHTML / gateShow / askDock / planDock; CSS 20047-20075).
struct ModeLine: View {
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        Group {
            if let status = vm.applying {
                line(label: status, steps: vm.steps) { EmptyView() }
            } else if !vm.isStreaming, let g = vm.openGate?.gate {
                line(label: "Waiting for your answer", steps: vm.steps) {
                    Segments(options: g.options(mode: vm.mode).map { ($0.label, $0) }) { vm.answerGate($0) }
                }
            } else if !vm.isStreaming, let a = vm.openAsk?.ask {
                line(label: "Waiting for your answer", steps: []) {
                    Segments(options: a.options.enumerated().map { ($0.element, $0.offset) }) { vm.answerAsk(index: $0) }
                }
            } else if !vm.isStreaming, let i = vm.openPlan, let p = vm.planState(at: i) {
                // ai.js planDock: "Plan ready", the parts as a chip that opens the plan, the answers.
                HStack(spacing: 10) {
                    PulseDot()
                    Text(vm.planBusy ? "Publishing the plan" : (p.parts > 0 ? "Plan ready" : "Nothing could be prepared"))
                        .font(LiaFont.ui(13)).foregroundStyle(AppConfig.text2)
                    Button { vm.planShown = i } label: {
                        Text(p.parts > 0 ? "\(p.parts) part" + (p.parts == 1 ? "" : "s") : "See why")
                            .font(LiaFont.ui(12, .bold)).foregroundStyle(AppConfig.ink)
                            .padding(.horizontal, 8).frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppConfig.line2))
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.fill, radius: 6)
                    Spacer(minLength: 8)
                    if vm.planBusy { ProgressView().controlSize(.small) }
                    else { Segments(options: PlanLogic.buttons(p).map { ($0.1, $0.0) }) { vm.answerPlan($0) } }
                }
                .frame(minHeight: 34).padding(.horizontal, 6)
            } else if vm.isStreaming, vm.live?.actStep != nil, !vm.steps.isEmpty {
                line(label: "Working", steps: vm.steps) { EmptyView() }
            }
        }
        .frame(maxWidth: AppConfig.composerMaxWidth)
        .transition(.opacity)
    }

    private func line<Trailing: View>(label: String, steps: [RunStep], @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            PulseDot()
            // In a narrow chat (the browser open) the words give way first; the answers never shrink to "…".
            Text(label).font(LiaFont.ui(13)).foregroundStyle(AppConfig.text2).lineLimit(1).layoutPriority(-1)
            if !steps.isEmpty { StepChip(steps: steps).layoutPriority(-0.5) }
            Spacer(minLength: 8)
            trailing().fixedSize().layoutPriority(1)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 6)
    }
}

/// 8 px dot breathing between text-3 and text (aiTkDot 1.3s).
struct PulseDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Circle().fill(on ? AppConfig.ink : AppConfig.text3)
            .frame(width: 8, height: 8)
            .scaleEffect(on ? 1.1 : 0.85)
            .opacity(on ? 1 : 0.55)
            .animation(reduce ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The answers. The first is filled with the text colour; the number above each is its key.
private struct Segments<T>: View {
    let options: [(String, T)]
    let pick: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { pick(o.1) } label: {
                    Text(o.0).font(LiaFont.ui(12.5, .semibold)).lineLimit(1)
                        .foregroundStyle(i == 0 ? AppConfig.composeBg : AppConfig.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == 0 ? AppConfig.ink : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.liaPlain)
                .liaHover(i == 0 ? .solid : .fill, radius: 6)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2))
        .fixedSize()
    }
}

/// The current step's name and the run as pips; hovering opens the plan of this run (ai.js tkChip).
private struct StepChip: View {
    let steps: [RunStep]

    private var current: RunStep { steps.last(where: { $0.state == .cur }) ?? steps[steps.count - 1] }

    var body: some View {
        // The site opens .ai__tkplan on hover; a panel under a moving pointer flickers, so a click opens it - as our
        // dropdown, 8 above the chip at its left edge, not a system popover with an arrow.
        DropdownButton(edge: .above, align: .leading, gap: 8, help: "Plan of this run", radius: 6, highlight: false) {
            HStack(spacing: 6) {
                Text(current.name).font(LiaFont.ui(12, .bold)).foregroundStyle(AppConfig.ink)
                pips
            }
            .padding(.horizontal, 8).frame(height: 24)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppConfig.line2))
            .contentShape(Rectangle())
            .liaHover(.fill, radius: 6)
        } menu: {
            // .ai__tkplan: --compose-bg, 1 px --line-2, radius 10, padding 8, 380 wide; no shadow.
            plan
                .background(RoundedRectangle(cornerRadius: 10).fill(AppConfig.composeBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppConfig.line2, lineWidth: 1))
                .padding(DropdownHost.inset)
        }
    }

    private var pips: some View {
        HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                RoundedRectangle(cornerRadius: 2)
                    .fill(s.state == .done ? AppConfig.ink : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(s.state == .no ? AppConfig.text4 : AppConfig.ink, lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .opacity(s.state == .no ? 0.5 : 1)
            }
        }
    }

    private var plan: some View {
        let done = steps.filter { $0.state == .done }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Plan \u{00b7} this run").font(LiaFont.ui(12, .semibold))
                Spacer()
                Text("\(done) of \(steps.count)").font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(s.state == .done ? AppConfig.accent : (s.state == .cur ? AppConfig.text3 : AppConfig.surface2))
                    }
                }
                .frame(width: g.size.width, height: 3)
            }
            .frame(height: 3)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(LiaFont.ui(12.5, .semibold))
                        if !s.subtitle.isEmpty { Text(s.subtitle).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(2) }
                    }
                    Spacer()
                    Text(s.state == .done ? "done" : s.state == .cur ? "now" : "skipped")
                        .font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text4)
                }
                .opacity(s.state == .no ? 0.55 : 1)
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}
