import SwiftUI
import WebKit

// The tour of an agent's applied changes over the person's Ads Manager tab: the window dims, a spotlight sits on
// the row (or the cell of the changed column) of each change, a glass card says "Budget: €50 → €80 · Met".
// The page is read in BrowserModel.agentWorld and at most scrolled to the row; never clicked or typed into.

/// Finds a changed object on an Ads Manager page, read-only.
@MainActor
enum ChangeLocate {
    /// The object's row (by id or name), narrowed to the changed column's cell when its header is found.
    /// Returns CSS pixels of the viewport ({x, y, w, h}) or false.
    static let js = #"""
    const norm = (s) => String(s || '').replace(/\s+/g, ' ').trim().toLowerCase();
    const shown = (el) => { const r = el.getBoundingClientRect(); return r.width >= 2 && r.height >= 2; };
    const want = norm(name), wid = String(id || ''), col = norm(label);
    if (!want && !wid) return false;
    let best = null;
    const rows = [...document.querySelectorAll('[role="row"], tr')].filter(shown);
    for (const r of rows) {
      const t = norm(r.innerText);
      if (!t) continue;
      if ((wid && t.indexOf(wid) >= 0) || (want && t.indexOf(want) >= 0)) {
        if (!best || r.getBoundingClientRect().height < best.getBoundingClientRect().height) best = r;
      }
    }
    if (!best && want) {
      const all = [...document.querySelectorAll('a, span, div, h1, h2, h3, input')].filter(shown);
      for (const e of all) {
        const t = norm(e.tagName === 'INPUT' ? e.value : e.innerText);
        if (t === want && (!best || e.getBoundingClientRect().width < best.getBoundingClientRect().width)) best = e;
      }
    }
    if (!best) return false;
    best.scrollIntoView({ block: 'center', inline: 'nearest' });
    let el = best;
    if (col) {
      const heads = [...document.querySelectorAll('[role="columnheader"], th')].filter(shown);
      const h = heads.find((x) => { const t = norm(x.innerText); return t && (t.indexOf(col) >= 0 || col.indexOf(t) >= 0); });
      if (h) {
        const hr = h.getBoundingClientRect(), mid = hr.left + hr.width / 2;
        const cells = [...best.querySelectorAll('[role="gridcell"], [role="cell"], td')].filter(shown);
        const c = cells.find((x) => { const r = x.getBoundingClientRect(); return r.left <= mid && r.right >= mid; });
        if (c) el = c;
      }
    }
    const r = el.getBoundingClientRect();
    const x = Math.max(0, r.left), y = Math.max(0, r.top);
    const w = Math.min(innerWidth, r.right) - x, hh = Math.min(innerHeight, r.bottom) - y;
    if (w < 2 || hh < 2) return false;
    return { x, y, w, h: hh };
    """#

    static func find(name: String, id: String?, label: String?, in webView: WKWebView) async -> CGRect? {
        let args: [String: Any] = ["name": name, "id": id ?? "", "label": label ?? ""]
        let v: Any? = await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(js, arguments: args, in: nil, in: BrowserModel.agentWorld) { result in
                switch result {
                case .success(let v): k.resume(returning: v)
                case .failure: k.resume(returning: nil)
                }
            }
        }
        guard let o = v as? [String: Any] else { return nil }
        func n(_ k: String) -> CGFloat? { (o[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = n("x"), let y = n("y"), let w = n("w"), let h = n("h") else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// CSS pixels of the viewport -> the window's content, top-left origin (SwiftUI's .global on the Mac).
    static func windowRect(_ css: CGRect, in webView: WKWebView) -> CGRect? {
        guard let content = webView.window?.contentView else { return nil }
        let k = webView.pageZoom * webView.magnification
        let local = CGRect(x: css.minX * k, y: css.minY * k, width: css.width * k, height: css.height * k)
        // WKWebView is flipped (top-left), so the CSS box maps directly; then into the content view.
        let inContent = webView.convert(local, to: content)
        if content.isFlipped { return inContent }
        return CGRect(x: inContent.minX, y: content.bounds.height - inContent.maxY, width: inContent.width, height: inContent.height)
    }
}

/// Mounted at the window root; draws nothing unless a change tour runs.
struct ChangeTourOverlay: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var center = ChangeCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        GeometryReader { g in
            if let run = center.tour, run.steps.indices.contains(run.index) {
                ChangeTourStage(run: run, size: g.size, origin: g.frame(in: .global).origin, ws: ws, reduce: reduce)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(center.tour != nil)
        .animation(reduce ? nil : WSMotion.micro, value: center.tour != nil)
        .onAppear { center.attach(ws) }
        .onDisappear { center.close() }
        // The person switches company or tab: the tour belongs to the page it was shown over.
        .onChange(of: ws.profileId) { _, _ in center.close() }
    }
}

private struct ChangeTourStage: View {
    let run: ChangeTourRun
    let size: CGSize
    let origin: CGPoint
    @ObservedObject var ws: WorkspaceModel
    let reduce: Bool
    @State private var cardHeight: CGFloat = 120

    private static let pad: CGFloat = 6
    private static let cardWidth: CGFloat = 320

    var body: some View {
        let hole = holeRect
        ZStack(alignment: .topLeading) {
            dim(hole)
            glow(hole)
            ChangeTourCard(run: run, ws: ws)
                .background(GeometryReader { g in
                    Color.clear.onAppear { cardHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in cardHeight = h }
                })
                .frame(width: Self.cardWidth)
                .position(cardCenter(hole))
                .animation(reduce ? nil : WSMotion.spring, value: run.index)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var holeRect: CGRect? {
        guard let r = run.rect else { return nil }
        let local = r.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -Self.pad, dy: -Self.pad)
        let clipped = local.intersection(CGRect(origin: .zero, size: size))
        return clipped.isNull || clipped.width < 4 ? nil : clipped
    }

    @ViewBuilder private func dim(_ hole: CGRect?) -> some View {
        let shape = SpotlightShape(hole: hole ?? .zero)
        shape.fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .animation(reduce ? nil : WSMotion.spring, value: hole ?? .zero)
            // A click on the dim closes the tour (it never reaches the page under it).
            .contentShape(shape, eoFill: true)
            .onTapGesture { ChangeCenter.shared.close() }
    }

    @ViewBuilder private func glow(_ hole: CGRect?) -> some View {
        if let h = hole {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .shadow(color: WS.blue.opacity(0.4), radius: 18)
                .frame(width: h.width, height: h.height)
                .position(x: h.midX, y: h.midY)
                .allowsHitTesting(false)
                .animation(reduce ? nil : WSMotion.spring, value: h)
        }
    }

    /// Below the spotlight if it fits, else above, else in the middle; always on screen.
    private func cardCenter(_ hole: CGRect?) -> CGPoint {
        let w = Self.cardWidth, h = cardHeight, m: CGFloat = 16, gap: CGFloat = 12
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let r = hole else { return middle }
        let x = min(max(r.midX, m + w / 2), max(m + w / 2, size.width - m - w / 2))
        if r.maxY + gap + h + m <= size.height { return CGPoint(x: x, y: r.maxY + gap + h / 2) }
        if r.minY - gap - h - m >= 0 { return CGPoint(x: x, y: r.minY - gap - h / 2) }
        return middle
    }
}

private struct ChangeTourCard: View {
    let run: ChangeTourRun
    @ObservedObject var ws: WorkspaceModel

    private var step: ChangeTourStep { run.steps[run.index] }

    var body: some View {
        let agent = ws.agent(step.change.agent)
        let name = agent?.name ?? step.change.agent.capitalized
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let agent { AgentAvatar(agent: agent, size: 28) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(line + " \u{00b7} " + name)
                        .font(LiaFont.ui(13.5, .semibold))
                        .foregroundStyle(WS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !step.change.title.isEmpty {
                        Text(step.change.title)
                            .font(LiaFont.ui(12))
                            .foregroundStyle(WS.text3)
                            .lineLimit(1)
                    }
                    if run.located && run.rect == nil {
                        Text("Not on this page")
                            .font(LiaFont.ui(11.5))
                            .foregroundStyle(WS.text3)
                    }
                }
                Spacer(minLength: 0)
                iconButton("xmark", help: "Close (Esc)") { ChangeCenter.shared.close() }
            }
            if run.steps.count > 1 {
                HStack(spacing: 6) {
                    Text("\(run.index + 1) of \(run.steps.count)")
                        .font(LiaFont.ui(11.5, .medium))
                        .foregroundStyle(WS.text3)
                    Spacer(minLength: 0)
                    iconButton("chevron.left", help: "Previous") { ChangeCenter.shared.go(-1) }
                        .disabled(run.index == 0)
                        .opacity(run.index == 0 ? 0.35 : 1)
                    iconButton("chevron.right", help: "Next") { ChangeCenter.shared.go(1) }
                        .disabled(run.index == run.steps.count - 1)
                        .opacity(run.index == run.steps.count - 1 ? 0.35 : 1)
                }
            }
        }
        .padding(14)
        .wsGlass(18)
        .shadow(color: Color.black.opacity(0.18), radius: 22, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change \(run.index + 1) of \(run.steps.count): " + line)
    }

    /// "Budget: €50 → €80"; a change without rows says what it was.
    private var line: String {
        guard let r = step.row else { return "Changed" }
        if r.old.isEmpty { return r.label + ": " + r.new }
        return r.label + ": " + r.old + " \u{2192} " + r.new
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WS.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(WS.soft))
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text(help))
    }
}
