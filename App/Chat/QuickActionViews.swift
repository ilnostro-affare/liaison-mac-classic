import SwiftUI

/// The sentence above the input (ai.js .ai__slashbar): fixed words and chips, dashed until set, blue when set;
/// the x discards it. Entity chips open a searchable list of the chat's campaigns and ad sets; text and number chips
/// open a small field (numbers with steppers).
struct QuickBarView: View {
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        if let q = vm.quick {
            HStack(alignment: .top, spacing: 4) {
                ChipFlowLayout(spacing: 3, lineSpacing: 4) {
                    ForEach(Array(q.command.parts.enumerated()), id: \.offset) { i, p in
                        if p.isChip { chip(q, i, p) }
                        else {
                            ForEach(Array(words(p.text).enumerated()), id: \.offset) { _, w in
                                Text(w).font(LiaFont.ui(12.5)).foregroundStyle(AppConfig.text2).fixedSize()
                            }
                        }
                    }
                }
                Button { vm.quick = nil } label: { LiaIcon("x", size: 13).frame(width: 20, height: 20).contentShape(Rectangle()) }
                    .buttonStyle(.liaPlain).liaHover(.icon, radius: 6, tint: AppConfig.text4).accessibilityLabel(Text("Discard"))
            }
            .padding(.horizontal, 6).padding(.top, 3).padding(.bottom, 4)
        }
    }

    /// The fixed words break where a sentence would (each word keeps its trailing space).
    private func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s { cur.append(ch); if ch == " " { out.append(cur); cur = "" } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    @ViewBuilder
    private func chip(_ q: QuickBar, _ i: Int, _ p: SlashPart) -> some View {
        let c = q.chips[i]
        let set = !(c?.value.isEmpty ?? true)
        let locked = c?.locked == true
        let label = Text((locked ? "\u{1F512} " : "") + q.label(i)).font(LiaFont.ui(11.5, .semibold)).lineLimit(1)
            .foregroundStyle(set ? AppConfig.ink : AppConfig.text3)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: 230)
            .background(Capsule().fill(locked ? AppConfig.ink.opacity(0.04) : set ? AppConfig.accent.opacity(0.07) : .clear))
            .overlay(Capsule().stroke(locked ? AppConfig.line2 : set ? AppConfig.accent.opacity(0.5) : AppConfig.line2,
                                      style: StrokeStyle(lineWidth: 1, dash: set || locked ? [] : [3, 2])))
            .contentShape(Capsule())
        if locked {
            label.liaTip("Uses the campaign's shared budget")
        } else {
            DropdownButton(edge: .above, gap: 8, radius: 100) { label } menu: {
                if p.required { EntityPicker(vm: vm, index: i, campaigns: p.kind == .campaignOrAdset) }
                else { ValuePicker(vm: vm, index: i, numeric: p.kind == .num, placeholder: p.placeholder ?? p.text) }
            }
            .fixedSize()
        }
    }
}

/// ai.js entityPicker: Search…, rows grouped by account with a live dot, the kind and the campaign under the name.
private struct EntityPicker: View {
    @ObservedObject var vm: ChatViewModel
    let index: Int
    let campaigns: Bool
    @State private var query = ""
    @FocusState private var focus: Bool

    var body: some View {
        DropdownPanelView(width: 320, padding: 4, radius: 12) {
            TextField("", text: $query, prompt: Text("Search\u{2026}").foregroundColor(AppConfig.text4))
                .textFieldStyle(.plain).font(LiaFont.ui(12.5)).focused($focus)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(AppConfig.line2).frame(height: 1) }
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.entitiesNoScope {
                        empty("Pick an account first, use the account chip above the chat.")
                    } else if let all = vm.entities {
                        let rs = rows(all)
                        if rs.isEmpty { empty("Nothing found") }
                        ForEach(Array(rs.enumerated()), id: \.offset) { n, e in
                            if n == 0 || rs[n - 1].accountName != e.accountName {
                                Text((e.accountName ?? "").uppercased()).font(LiaFont.ui(9.5, .semibold)).tracking(0.57)
                                    .foregroundStyle(AppConfig.text4).padding(.horizontal, 11).padding(.top, 8).padding(.bottom, 4)
                            }
                            Row(e: e) {
                                DropdownHost.shared.close()
                                vm.quick?.pick(e, at: index, manyAccounts: vm.manyAccounts)
                            }
                        }
                    } else {
                        ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2).frame(height: 30).padding(5) }
                    }
                }
            }
            .frame(height: 230)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = true } }
        .task { await vm.loadEntities() }
    }

    private func rows(_ all: [SlashEntity]) -> [SlashEntity] {
        let q = query.lowercased()
        return Array(all.filter { (campaigns || $0.kind == "ad set") && (q.isEmpty || $0.name.lowercased().contains(q) || ($0.campaign ?? "").lowercased().contains(q)) }.prefix(60))
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text4).padding(.horizontal, 12).padding(.vertical, 10)
    }

    private struct Row: View {
        let e: SlashEntity
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(spacing: 9) {
                    Circle().fill(e.active ? Color(red: 0x3f / 255, green: 0xae / 255, blue: 0x6a / 255) : AppConfig.line2).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).font(LiaFont.ui(12)).foregroundStyle(AppConfig.ink).lineLimit(1)
                        Text(e.kind + (e.campaign.map { " \u{00b7} " + $0 } ?? "")).font(LiaFont.ui(10)).foregroundStyle(AppConfig.text4).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .onHover { hover = $0 }
            .liaPointer()
        }
    }
}

/// ai.js inputPicker: one field; a number gets up and down steppers. Typing updates the chip live; Return closes.
private struct ValuePicker: View {
    @ObservedObject var vm: ChatViewModel
    let index: Int
    let numeric: Bool
    let placeholder: String
    @State private var value = ""
    @FocusState private var focus: Bool

    var body: some View {
        DropdownPanelView(minWidth: numeric ? 0 : 150, padding: 4, radius: 12) {
            HStack(spacing: 5) {
                TextField("", text: $value, prompt: Text(placeholder).foregroundColor(AppConfig.text4))
                    .textFieldStyle(.plain)
                    .font(numeric ? LiaFont.ui(13, .semibold) : LiaFont.ui(12.5))
                    .multilineTextAlignment(numeric ? .center : .leading)
                    .frame(width: numeric ? 64 : min(320, max(130, CGFloat(value.count + 1) * 7.4)))
                    .focused($focus)
                    .onSubmit { DropdownHost.shared.close() }
                    .onChange(of: value) { _, v in vm.quick?.chips[index]?.value = v.trimmingCharacters(in: .whitespaces) }
                if numeric {
                    VStack(spacing: 2) {
                        stepper("caret-up") { step(1) }
                        stepper("caret-down") { step(-1) }
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
        }
        .onAppear {
            value = vm.quick?.chips[index]?.value ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = true }
        }
    }

    private func step(_ d: Double) {
        let n = max(0, (Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0) + d)
        let r = (n * 100).rounded() / 100
        value = r == r.rounded() ? String(Int(r)) : String(r)
    }

    private func stepper(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LiaIcon(icon, size: 9).frame(width: 20, height: 13)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppConfig.line2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain).liaHover(.icon, radius: 5, tint: AppConfig.text3)
    }
}

/// The palette that opens on "/" (ai.js .ai-slash): the command in bold, what it does under it; arrows, Return or Tab.
struct SlashPalette: View {
    let rows: [SlashCommand]
    let hot: Int
    let onHover: (Int) -> Void
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
                Button { onPick(c) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.cmd).font(LiaFont.ui(12.5, .semibold)).foregroundStyle(AppConfig.ink)
                        Text(c.desc).font(LiaFont.ui(10.5)).foregroundStyle(AppConfig.text4).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(i == hot ? AppConfig.surface2 : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain)
                .onHover { if $0 { onHover(i) } }
                .liaPointer()
            }
        }
        .padding(4)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppConfig.ddBg).shadow(color: .black.opacity(0.16), radius: 11, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppConfig.line2))
    }
}

/// Lays children out left to right and wraps them, like inline text.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += line + lineSpacing; x = 0; line = 0 }
            x += sz.width + spacing
            line = max(line, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        // Each line is centred vertically on its tallest item, so words sit level with the chips.
        var rows: [[(Subviews.Element, CGSize)]] = [[]]
        var rx: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if rx > 0 && rx + sz.width > bounds.width { rows.append([]); rx = 0 }
            rows[rows.count - 1].append((s, sz))
            rx += sz.width + spacing
        }
        for row in rows {
            line = row.map(\.1.height).max() ?? 0
            x = bounds.minX
            for (s, sz) in row {
                s.place(at: CGPoint(x: x, y: y + (line - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += line + lineSpacing
        }
    }
}
