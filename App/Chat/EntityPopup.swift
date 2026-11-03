import SwiftUI
import AppKit

// The entity popups of Lia's answer (ai.js entPopup / entPopupMany, CSS .lia-entpop*). Opened from a chip in
// the answer (AnswerText), in a DropdownHost panel at the click point, under the chip as the site places
// it. Read-only: Copy puts the id on the clipboard, Use puts the words into the composer, Open creative opens
// the ad popup over the chat. Nothing here writes to Meta.

extension Notification.Name {
    /// window.LiaPutText: userInfo["text"] is appended to the composer (ChatScreen).
    static let liaPutText = Notification.Name("lia.putText")
    /// The ad popup over the chat column: userInfo["id"], userInfo["name"] (ChatScreen, WidgetActions.openAd).
    static let liaOpenAd = Notification.Name("lia.openAd")
}

@MainActor
enum EntityPopup {
    /// `anchor` is the chip's own box on screen (AnswerText); without it, a rect a chip high around the pointer stands in.
    /// The popup opens 8 px under the chip's bottom, its left edge at the chip's.
    static func show(_ link: EntityLink, ents: [String: ChatEntity], anchor chip: NSRect? = nil) {
        let p = NSEvent.mouseLocation
        let anchor: NSRect = chip.map { NSRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }
            ?? NSRect(x: p.x, y: p.y - 10, width: 1, height: 20)
        let window: NSWindow? = NSApp.mainWindow ?? NSApp.keyWindow
        switch link {
        case .entity(let id):
            DropdownHost.shared.toggle("ent:" + id, anchor: anchor, in: window, edge: .below, align: .leading, gap: 8) {
                EntityPopupView(id: id, ents: ents)
            }
        case .namesake(let key):
            let groups = EntityChips.namesakes(key, ents: ents)
            guard !groups.isEmpty else { return }   // entPopupMany: no hits, no popup
            DropdownHost.shared.toggle("entname:" + key, anchor: anchor, in: window, edge: .below, align: .leading, gap: 8) {
                NamesakePopupView(groups: groups, ents: ents)
            }
        }
    }

    static func use(_ text: String) {
        NotificationCenter.default.post(name: .liaPutText, object: nil, userInfo: ["text": text])
    }
}

/// .lia-entpop: dd-bg, 1 px line-2, radius 12, padding 11 x 12, 190 to 300 wide.
private struct EntPopShell<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        DropdownPanelView(width: width, minWidth: 190, padding: 0, radius: 12) {
            content()
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: width == nil ? 300 : nil, alignment: .leading)
        }
    }
}

/// .lia-entpop__lvl .dot: 6 px, accent; `.off` text-4.
private struct EntDot: View {
    var on = true
    var body: some View {
        Circle().fill(on ? AppConfig.accent : AppConfig.text4).frame(width: 6, height: 6)
    }
}

/// .lia-entpop__ind: 13 px in, a dashed line-2 rule on the left, 10 px to the text.
private struct EntIndent<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Color.clear).frame(width: 1)
                .overlay(Line().stroke(AppConfig.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            VStack(alignment: .leading, spacing: 0) { content() }.padding(.leading, 10)
        }
        .padding(.leading, 13)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            return p
        }
    }
}

/// entPopup: the tree (campaign, the entity, its children), then Copy and Use.
struct EntityPopupView: View {
    let id: String
    let ents: [String: ChatEntity]
    @State private var copied = false

    private var tree: EntityChips.Tree { EntityChips.tree(id: id, ents: ents) }

    var body: some View {
        let t = tree
        EntPopShell {
            VStack(alignment: .leading, spacing: 0) {
                if let parent = t.parent {
                    level(name: parent, kind: "campaign", strong: true, on: true)
                    EntIndent { entityAndKids(t) }
                } else {
                    entityAndKids(t)
                }
                Rectangle().fill(AppConfig.line2).frame(height: 1).padding(.top, 9)
                HStack(spacing: 7) {
                    Button {
                        Clipboard.copy(id)
                        copied = true
                    } label: {
                        HStack(spacing: 4) {
                            if !copied { LiaIcon("copy", size: 12) }
                            Text(copied ? "Copied" : "Copy").font(LiaFont.ui(10, .medium))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppConfig.line2, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.fill, radius: 7, tint: AppConfig.text3)
                    .liaTip(id)
                    Spacer(minLength: 0)
                    Button {
                        EntityPopup.use(EntityChips.useText(id: id, entity: ents[id]))
                        DropdownHost.shared.close()
                    } label: {
                        Text("Use").font(LiaFont.ui(10, .semibold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7).fill(AppConfig.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.solid)
                }
                .padding(.top, 9)
            }
        }
    }

    @ViewBuilder
    private func entityAndKids(_ t: EntityChips.Tree) -> some View {
        level(name: t.name, kind: t.kind, strong: true, on: true)
        if !t.kids.isEmpty {
            EntIndent {
                ForEach(t.kids, id: \.id) { k in level(name: k.name, kind: k.kind, strong: false, on: false) }
            }
        }
    }

    /// .lia-entpop__tree: 11.5 regular text-3, the entity's own name 600 in --text; a row is 2 px top and bottom.
    private func level(name: String, kind: String?, strong: Bool, on: Bool) -> some View {
        let nice = EntityChips.kindNice(kind)
        let label: Text = strong
            ? Text(verbatim: name).font(LiaFont.ui(11.5, .semibold)).foregroundColor(AppConfig.ink)
            : Text(verbatim: name).foregroundColor(AppConfig.text3)
        let suffix: Text = Text(verbatim: nice.isEmpty ? "" : " \u{00B7} " + nice).foregroundColor(AppConfig.text3)
        return HStack(spacing: 6) {
            EntDot(on: on)
            Text("\(label)\(suffix)").font(LiaFont.ui(11.5)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: 276, alignment: .leading)
    }
}

/// entPopupMany: "<name> · N entities share this name", grouped by campaign, a ··· menu per row
/// (Open creative for an ad, Copy id, Use in chat). Never picks one itself.
struct NamesakePopupView: View {
    let groups: [EntityChips.Group]
    let ents: [String: ChatEntity]

    private var count: Int { groups.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        let title = groups.first?.items.first?.name ?? ""
        // .lia-entpop--many: 306 wide, at most 340 high, scrolls.
        let estimate: CGFloat = 22 + CGFloat(groups.count) * 26 + CGFloat(count) * 27
        let height: CGFloat = min(340 - 22, estimate)
        EntPopShell(width: 306) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title + " \u{00B7} \(count) entities share this name")
                    .font(LiaFont.ui(11, .bold)).foregroundStyle(AppConfig.text3)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 2).padding(.top, 1).padding(.bottom, 9)
                ScrollView(.vertical, showsIndicators: estimate > height) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.title) { g in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: g.title).font(LiaFont.ui(10, .bold)).tracking(0.3).foregroundStyle(AppConfig.text4)
                                    .lineLimit(1).truncationMode(.tail)
                                    .padding(.horizontal, 4).padding(.top, 5).padding(.bottom, 3)
                                ForEach(g.items, id: \.id) { it in NamesakeRow(item: it, entity: ents[it.id]) }
                            }
                            .padding(.bottom, 5)
                        }
                    }
                    .frame(width: 282, alignment: .leading)
                }
                .frame(width: 282, height: height)
            }
        }
    }
}

/// .lia-entpop__row: name · kind (11.5 / 500 text-2), the ··· button; hover surface-2, radius 8. Its `.dot` span has
/// no rule outside `.lia-entpop__lvl`, so the site draws nothing there but the 8 px gap: 20 px in.
private struct NamesakeRow: View {
    let item: EntityChips.Item
    let entity: ChatEntity?
    @State private var hover = false
    @State private var box = AnchorBox()

    var body: some View {
        let nice = EntityChips.kindNice(item.kind)
        HStack(spacing: 8) {
            Text(verbatim: item.name + (nice.isEmpty ? "" : " \u{00B7} " + nice))
                .font(LiaFont.ui(11.5, .medium)).foregroundStyle(AppConfig.text2)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button { openMenu() } label: {
                Text(verbatim: "\u{00B7}\u{00B7}\u{00B7}").font(LiaFont.ui(13)).foregroundStyle(hover ? AppConfig.text2 : AppConfig.text4)
                    .padding(.horizontal, 5).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 6)
            .accessibilityLabel("More")
        }
        .padding(.leading, 20).padding(.trailing, 4).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : Color.clear))
        .background(AnchorReader(box: box))
        .onHover { hover = $0 }
    }

    private func openMenu() {
        let id = item.id
        let name = item.name
        let isAd = ["ad", "creative"].contains((item.kind ?? "").lowercased())
        let use = EntityChips.useText(id: id, entity: entity ?? ChatEntity(name: name, kind: item.kind))
        DropdownHost.shared.showSub(row: box.screenRect, growsUp: false) {
            NamesakeMenu(isAd: isAd, onOpen: {
                DropdownHost.shared.close()
                NotificationCenter.default.post(name: .liaOpenAd, object: nil, userInfo: ["id": id, "name": name])
            }, onCopy: {
                Clipboard.copy(id)
            }, onUse: {
                EntityPopup.use(use)
                DropdownHost.shared.close()
            })
        }
    }
}

/// .lia-entpop__menu: dd-bg, radius 10, padding 4, rows 7 x 10, 11.5 / 500 text-2, hover surface-2.
private struct NamesakeMenu: View {
    let isAd: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onUse: () -> Void
    @State private var copied = false

    var body: some View {
        DropdownPanelView(minWidth: 146, padding: 4, radius: 10) {
            if isAd { MenuRow(title: "Open creative", action: onOpen) }
            MenuRow(title: copied ? "Copied" : "Copy id") { onCopy(); copied = true }
            MenuRow(title: "Use in chat", action: onUse)
        }
    }

    private struct MenuRow: View {
        let title: String
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                Text(title).font(LiaFont.ui(11.5, .medium)).foregroundStyle(hover ? AppConfig.ink : AppConfig.text2)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(hover ? AppConfig.surface2 : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .onHover { hover = $0 }
            .liaPointer()
        }
    }
}
