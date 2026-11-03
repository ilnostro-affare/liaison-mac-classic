import SwiftUI

/// "Quick answer" above the input (ai.js quizBarMount, CSS .ai__quizbar): the composer's own surface, radius 18,
/// 11x14 inside; a quiet x top right, the label, the question, up to five options and, for an entity choice,
/// "Choose myself / search the whole account". A tap that arrives while Lia is still answering flashes and waits.
struct QuizBar: View {
    @ObservedObject var vm: ChatViewModel
    let quiz: Quiz
    let projectAccount: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("QUICK ANSWER")
                .font(LiaFont.ui(9.5, .semibold)).tracking(0.67).foregroundStyle(AppConfig.text4)
                .padding(.trailing, 24)
            if let q = quiz.question {
                Text(q).font(LiaFont.ui(13, .medium)).foregroundStyle(AppConfig.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -2).padding(.bottom, 2)
                    .padding(.trailing, 24)
            }
            if !quiz.options.isEmpty {
                QuizFlowLayout(spacing: 7) {
                    ForEach(quiz.options) { o in
                        QuizOptionButton(option: o) { vm.answerQuiz(o.send, projectAccount: projectAccount) }
                    }
                }
            }
            if quiz.isEntity {
                QuizSelfButton(vm: vm, projectAccount: projectAccount).padding(.top, 3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppConfig.composeBg))
        // .ai__quizbar: no border in dark, line-2 in light - the composer's own line.
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppConfig.composeLine, lineWidth: 1))
        .overlay(alignment: .topTrailing) { QuizDismissButton { vm.dismissQuiz() }.padding(.top, 6).padding(.trailing, 9) }
        .transition(.opacity)
    }
}

/// .ai__quizbar__x: 15 px x at 55% until hovered.
private struct QuizDismissButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("\u{00d7}").font(LiaFont.ui(15))
                .foregroundStyle(hover ? AppConfig.text2 : AppConfig.text4)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? AppConfig.surface2 : Color.clear))
                .opacity(hover ? 1 : 0.55)
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel("Dismiss")
    }
}

/// .ai__quizbar__opt: 12.5 px medium on a faint fill, line-2 border, radius 11, at least 46 tall; the hint under it.
private struct QuizOptionButton: View {
    let option: QuizOption
    let send: () -> Bool
    @State private var hover = false
    @State private var flash = 0

    var body: some View {
        Button {
            if !send() { flash += 1 }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let h = option.hint {
                    Text(h).font(LiaFont.ui(10.5)).foregroundStyle(AppConfig.text4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(minHeight: 46, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(hover ? AppConfig.accent.opacity(0.07) : QuizStyle.optionFill))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(hover ? AppConfig.accent.opacity(0.55) : AppConfig.line2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .liaPointer()
        .modifier(WaitFlash(tick: flash))
    }
}

/// .ai__quizbar__self: the full-width dashed option that opens the whole account's ad sets.
private struct QuizSelfButton: View {
    @ObservedObject var vm: ChatViewModel
    let projectAccount: String?
    @State private var hover = false

    var body: some View {
        DropdownButton(edge: .above, align: .leading, gap: 8, radius: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose myself").font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.text3)
                Text("search the whole account").font(LiaFont.ui(10.5)).foregroundStyle(AppConfig.text4)
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(hover ? AppConfig.accent.opacity(0.07) : QuizStyle.optionFill))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(hover ? AppConfig.accent.opacity(0.55) : AppConfig.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        } menu: {
            QuizPicker(vm: vm, projectAccount: projectAccount)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// ai.js quizSelfPicker (.ai__quizpick): 330 wide, a search field, the account's ad sets grouped under their campaign
/// with a live dot; one tap sends "[quick_action] <name> (id <id>)".
private struct QuizPicker: View {
    @ObservedObject var vm: ChatViewModel
    let projectAccount: String?
    @State private var query = ""
    @FocusState private var focus: Bool

    private struct CampaignGroup: Identifiable {
        let campaign: String
        let rows: [SlashEntity]
        var id: String { campaign }
    }

    var body: some View {
        DropdownPanelView(width: 330, padding: 0, radius: 14) {
            HStack(spacing: 8) {
                LiaIcon("search", size: 15).foregroundStyle(AppConfig.text4)
                TextField("", text: $query, prompt: Text("Search ad sets").foregroundColor(AppConfig.text4))
                    .textFieldStyle(.plain).font(LiaFont.ui(13)).foregroundStyle(AppConfig.ink).focused($focus)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(AppConfig.line2).frame(height: 1) }
            list
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = true } }
        .task { await vm.loadEntities() }
    }

    @ViewBuilder
    private var list: some View {
        if vm.entitiesNoScope {
            empty("Could not read the account")
        } else if let all = vm.entities {
            let gs: [CampaignGroup] = groups(all)
            if gs.isEmpty {
                empty("Nothing found")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(gs) { g in
                            Section {
                                ForEach(g.rows) { e in QuizPickRow(entity: e, send: { pick(e) }) }
                            } header: { header(g.campaign) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(height: listHeight(gs))
            }
        } else {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2).frame(height: 28)
                }
            }
            .padding(10)
        }
    }

    private func pick(_ e: SlashEntity) -> Bool {
        let sent = vm.answerQuiz(Quiz.pickText(name: e.name, id: e.id), projectAccount: projectAccount)
        if sent { DropdownHost.shared.close() }
        return sent
    }

    /// Filtered by name or campaign, grouped by campaign in the order they first appear ("—" for none).
    private func groups(_ all: [SlashEntity]) -> [CampaignGroup] {
        let q = query.lowercased()
        var order: [String] = []
        var by: [String: [SlashEntity]] = [:]
        for e in all where e.kind == "ad set" {
            let camp = e.campaign ?? ""
            guard q.isEmpty || e.name.lowercased().contains(q) || camp.lowercased().contains(q) else { continue }
            let key = camp.isEmpty ? "\u{2014}" : camp
            if by[key] == nil { order.append(key); by[key] = [] }
            by[key]?.append(e)
        }
        return order.map { CampaignGroup(campaign: $0, rows: by[$0] ?? []) }
    }

    /// The panel grows with its rows up to the site's 380 px (the search line takes the rest).
    private func listHeight(_ gs: [CampaignGroup]) -> CGFloat {
        let rows = gs.reduce(0) { $0 + $1.rows.count }
        return min(CGFloat(rows) * 33 + CGFloat(gs.count) * 28 + 6, 336)
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(LiaFont.ui(9.5, .semibold)).tracking(0.57).foregroundStyle(AppConfig.text4)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 9).padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppConfig.ddBg)
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text4)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// .ai__quizpick__row: the dot (accent when active), the name; a refused pick flashes.
private struct QuizPickRow: View {
    let entity: SlashEntity
    let send: () -> Bool
    @State private var hover = false
    @State private var flash = 0

    var body: some View {
        Button {
            if !send() { flash += 1 }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(entity.active ? AppConfig.accent : AppConfig.text4).frame(width: 7, height: 7)
                Text(entity.name).font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? AppConfig.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .modifier(WaitFlash(tick: flash))
    }
}

private enum QuizStyle {
    /// rgba(255,255,255,.04) on both themes, as the site writes it.
    static let optionFill = Color.white.opacity(0.04)
}

/// ai.js qzWaitFlash / .is-wait: a refused tap dims to 45% and back over half a second, replayed on every tap.
struct WaitFlash: ViewModifier {
    let tick: Int
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onChange(of: tick) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) { dim = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeInOut(duration: 0.25)) { dim = false }
                }
            }
    }
}

/// flex-wrap with a 7 px gap: each option takes its natural width, capped at the row, wrapping its text when longer.
struct QuizFlowLayout: Layout {
    var spacing: CGFloat = 7

    private func sizes(_ subviews: Subviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { s in
            let ideal = s.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            return s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    /// Rows of subview indices with their line heights.
    private func rows(_ sz: [CGSize], maxWidth: CGFloat) -> [(items: [Int], height: CGFloat)] {
        var out: [(items: [Int], height: CGFloat)] = []
        var cur: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for (i, s) in sz.enumerated() {
            if !cur.isEmpty && x + s.width > maxWidth {
                out.append((cur, h)); cur = []; x = 0; h = 0
            }
            cur.append(i)
            x += s.width + spacing
            h = max(h, s.height)
        }
        if !cur.isEmpty { out.append((cur, h)) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let sz = sizes(subviews, maxWidth: maxW)
        let rs = rows(sz, maxWidth: maxW)
        let height = rs.reduce(CGFloat(0)) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        let widest = rs.map { r in r.items.reduce(CGFloat(0)) { $0 + sz[$1].width } + spacing * CGFloat(max(r.items.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sz = sizes(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for r in rows(sz, maxWidth: bounds.width) {
            var x = bounds.minX
            for i in r.items {
                // align-items: center within the line
                subviews[i].place(at: CGPoint(x: x, y: y + (r.height - sz[i].height) / 2), proposal: ProposedViewSize(sz[i]))
                x += sz[i].width + spacing
            }
            y += r.height + spacing
        }
    }
}
