import SwiftUI

/// The plan, as the site's popup draws it (ai.js planPaint 2523): the new tree to be created paused, the audience
/// variants, the changes with their switches, the refused parts; after publishing, what happened.
/// On the Mac nothing is edited here: parts are switched off or a variant picked.
struct PlanSheet: View {
    @ObservedObject var vm: ChatViewModel
    let index: Int
    var onOpenCreated: (String, String) -> Void = { _, _ in }
    @Environment(\.liaDismiss) private var dismiss

    var body: some View {
        let p = vm.planState(at: index)
        VStack(alignment: .leading, spacing: 0) {
            header(p)
            Divider().overlay(AppConfig.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let p { content(p) }
                }
                .padding(16)
            }
            if let p, !p.done, vm.openPlan == index {
                Divider().overlay(AppConfig.line)
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(Array(PlanLogic.buttons(p).enumerated()), id: \.offset) { i, b in
                        Button(b.1) { vm.answerPlan(b.0); if b.0 == .no { dismiss() } }
                            .buttonStyle(LiaButtonStyle(primary: i == 0))
                            .disabled(vm.planBusy)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 620, height: 560)
        .background(AppConfig.ddBg)
    }

    private func header(_ p: PlanState?) -> some View {
        HStack(spacing: 10) {
            Text(title(p)).font(LiaFont.ui(13, .semibold)).foregroundStyle(AppConfig.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppConfig.accentSoft))
            Text(subtitle(p)).font(LiaFont.ui(13)).foregroundStyle(AppConfig.text3).lineLimit(1)
            Spacer()
            if vm.planBusy { ProgressView().controlSize(.small) }
            LiaModalCloseButton(size: 28) { dismiss() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func title(_ p: PlanState?) -> String {
        guard let p, p.done else { return "Plan" }
        switch p.answer { case "stopped": return "Cut off"; case "no": return "Plan"; case "apply": return "Applied"; default: return "Published" }
    }

    private func subtitle(_ p: PlanState?) -> String {
        guard let p else { return "" }
        if p.done {
            if p.answer == "no" { return p.creates.isEmpty ? "Not applied" : "Not published" }
            return "\(p.results.filter { $0.createdId != nil || $0.ok }.count) done"
        }
        if !p.creates.isEmpty { return (p.create("campaign")?.title ?? "New campaign") + " \u{00b7} not published" }
        let n = p.edits.count + p.refused.count
        return "\(n) change" + (n == 1 ? "" : "s")
    }

    @ViewBuilder
    private func content(_ p: PlanState) -> some View {
        if p.done {
            lead(doneLead(p))
            ForEach(Array(p.results.enumerated()), id: \.offset) { _, r in
                row(icon: r.kind, kind: r.k, name: r.title, line: r.what, why: r.error) {
                    if let id = r.createdId {
                        Text("\u{2026}" + String(id.suffix(4))).font(LiaFont.mono(11)).foregroundStyle(AppConfig.text4)
                        Button("Open") { onOpenCreated(id, r.kind) }.buttonStyle(LiaButtonStyle())
                    }
                }
            }
        } else {
            let old = vm.openPlan != index
            let pickMiss = p.variants.count > 1 && !p.variants.contains { $0.id == p.pick } && p.pick != nil
            if old { lead("A newer message replaced this plan. It is shown as it was; nothing here can be sent.") }
            else if let e = vm.planError { lead(e, error: true) }
            else if pickMiss { lead("The first audience was refused by Meta. Pick one of these to put it on the ad set.", error: true) }
            else { lead(p.creates.isEmpty ? "Switch off anything you do not want sent." : "Nothing exists in Meta until you publish.") }

            if p.variants.count > 1 {
                section("Audience")
                ForEach(Array(p.variants.enumerated()), id: \.element.id) { i, v in
                    let on = v.id == (p.pick ?? p.variants.first?.id)
                    Button { vm.pickVariant(v.id, at: index) } label: {
                        HStack(spacing: 10) {
                            Circle().strokeBorder(on ? AppConfig.accent : AppConfig.line3, lineWidth: on ? 5 : 1.5).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(v.variant ?? "Variant \(i + 1)").font(LiaFont.ui(13, .semibold))
                                    if i == 0 {
                                        Text("Lia\u{2019}s pick").font(LiaFont.ui(10.5, .semibold)).foregroundStyle(AppConfig.accent)
                                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(AppConfig.accentSoft))
                                    }
                                }
                                let aud = PlanLogic.audienceLine(v.args)
                                if !aud.isEmpty && aud.replacingOccurrences(of: " ", with: "") != (v.variant ?? "").replacingOccurrences(of: " ", with: "") {
                                    Text(aud).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                                }
                            }
                            Spacer()
                            if let reach = v.diff.first(where: { $0.label == "Estimated audience" }) {
                                Text(reach.new.replacingOccurrences(of: " people", with: "")).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                            }
                        }
                        .padding(10).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? AppConfig.surface2 : .clear))
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.fill, radius: 10)
                    .disabled(old || vm.planBusy)
                }
            }
            if !p.creates.isEmpty {
                section("Will be created, paused")
                ForEach(["campaign", "adset", "ad"], id: \.self) { kind in
                    if let it = p.create(kind) {
                        row(icon: kind, kind: it.kindWord, name: it.title.isEmpty ? (JSONRead.string(it.args, "name") ?? "New " + it.kindWord.lowercased()) : it.title,
                            line: kind == "adset" ? [PlanLogic.audienceLine(it.args), it.diffLine].filter { !$0.isEmpty }.joined(separator: " \u{00b7} ") : it.diffLine,
                            why: nil) { EmptyView() }
                    }
                }
            }
            if !p.refused.isEmpty {
                if !p.creates.isEmpty || !p.edits.isEmpty { section("Not prepared") }
                ForEach(p.refused) { x in
                    row(icon: x.createKind ?? "change", kind: x.kindWord, name: x.title, line: nil, why: "Meta: \u{201c}" + (x.error ?? "") + "\u{201d}") { EmptyView() }
                        .opacity(0.6)
                }
            }
            if !p.edits.isEmpty {
                if !p.creates.isEmpty || !p.refused.isEmpty { section("Changes") }
                ForEach(p.edits) { x in
                    row(icon: "change", kind: x.kindWord, name: x.title, line: x.diffLine, why: nil) {
                        PlanSwitch(on: !x.off, disabled: old || vm.planBusy) { vm.togglePlanItem(x.id, at: index) }
                    }
                    .opacity(x.off ? 0.55 : 1)
                }
            }
        }
    }

    private func doneLead(_ p: PlanState) -> String {
        switch p.answer {
        case "stopped": return "Publishing was cut off. Check Ads Manager: part of the tree may be there, paused."
        case "no": return p.creates.isEmpty ? "Not applied. Nothing was sent to Meta." : "Not published. Nothing was sent to Meta."
        case "apply": return "Applied and read back from Meta."
        case "publish_on": return "Published and turned on. Read back from Meta."
        default: return "Published, paused. Turning on is a separate question."
        }
    }

    private func lead(_ t: String, error: Bool = false) -> some View {
        Text(t).font(LiaFont.ui(12.5)).foregroundStyle(error ? AppConfig.bad : AppConfig.text3)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6).padding(.bottom, 6)
    }

    private func section(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(11, .bold)).foregroundStyle(AppConfig.text4).padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 2)
    }

    private func row<T: View>(icon: String, kind: String, name: String, line: String?, why: String?, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2)
                LiaIcon(icon == "campaign" ? "ads" : icon == "adset" ? "adset" : icon == "ad" ? "ad" : "pencil-simple", size: 17)
                    .foregroundStyle(AppConfig.text2)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind).font(LiaFont.ui(11)).foregroundStyle(AppConfig.text4)
                Text(name).font(LiaFont.ui(13.5, .semibold)).lineLimit(1)
                if let line, !line.isEmpty { Text(line).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).lineLimit(2) }
                if let why { Text(why).font(LiaFont.ui(12)).foregroundStyle(AppConfig.bad).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
    }
}

/// ai.js button.lpl__sw: 34x20, radius 10, --line-3 off and the accent on, a 16 px white knob 2 in from the edge
/// with a 1 px shadow; 40% when disabled.
private struct PlanSwitch: View {
    let on: Bool
    let disabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? AppConfig.accent : AppConfig.line3)
                Circle().fill(Color.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1).padding(2)
            }
            .frame(width: 34, height: 20)
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
    }
}
