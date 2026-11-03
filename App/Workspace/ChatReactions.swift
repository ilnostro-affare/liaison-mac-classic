import SwiftUI

// Telegram-style reactions on an agent's message (the product's ask 9): a small round heart beside the hovered
// bubble's bottom-right corner (a click reacts with it, again takes it back), hovering it opens the picker growing
// upwards with every reaction of `DlgMark.reactions`; a reaction set shows as a chip under the bubble: the emoji and
// the faces of who reacted (only the person for now; the chip already holds several for shared workspaces).
// Real colour emoji: the system font draws them with Apple Color Emoji.
// (the product's ask 2): only three. ❤️ is the like and the like is the favourite (Favourites, the agent's profile);
// 👍/👎 are the feedback on the answer. A message can hold ❤️ and one thumb at once; the chips show both.

/// One person who reacted.
struct ChatReactor: Identifiable, Equatable {
    let id: String
    /// Initials for someone else's face; the person's own face is drawn by `ChatMeFace`.
    var initials: String = ""
    var mine: Bool = false

    static let me = ChatReactor(id: "me", mine: true)
}

/// One emoji on a message and who reacted with it.
struct ChatReaction: Identifiable, Equatable {
    let emoji: String
    var reactors: [ChatReactor]
    var id: String { emoji }
    var mine: Bool { reactors.contains { $0.mine } }

    /// What the picker offers, bottom to top: the like, then the thumbs.
    static let offered = [ChatLocal.heart] + ChatLocal.thumbs

    /// The person's own marks as the chips' list: the like first, then the thumb (empty when there is neither).
    static func mine(liked: Bool, thumb: String?) -> [ChatReaction] {
        var out: [ChatReaction] = []
        if liked { out.append(ChatReaction(emoji: ChatLocal.heart, reactors: [.me])) }
        if let thumb, ChatLocal.thumbs.contains(thumb) { out.append(ChatReaction(emoji: thumb, reactors: [.me])) }
        return out
    }

    /// What VoiceOver and the menus call each reaction.
    static func name(_ emoji: String) -> String {
        switch emoji {
        case "\u{2764}\u{FE0F}": return "Like"
        case "\u{1F44D}": return "Thumbs Up"
        case "\u{1F44E}": return "Thumbs Down"
        default: return "Reaction"
        }
    }
}

/// The person's small face: two letters of their name (Settings \u{203A} Account) on the dark circle; "U" when there is
/// no name (a sign-up by email gives none). Cached by LibraryStore (`store`), so it never waits for the network.
struct ChatMeFace: View {
    var size: CGFloat = 18
    @AppStorage(ChatMeFace.initialsKey) private var initials = ""

    static let initialsKey = "lia_profile_initials"
    static let nameKey = "lia_profile_name"

    /// The person's name as they set it, "" when there is none (Memberstack fills the full name from the email).
    static func realName(_ p: MemberProfile) -> String {
        let full = p.fullName.trimmingCharacters(in: .whitespaces)
        if !p.firstName.isEmpty { return full.isEmpty ? p.firstName : full }
        let emailName = p.email.split(separator: "@").first.map(String.init) ?? ""
        if full.isEmpty || full == "Account" || full == emailName { return "" }
        return full
    }

    /// Two letters: the first of the first two words, else the first two of the only word.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return (String(a) + String(b)).uppercased() }
        guard let w = words.first else { return "" }
        return String(w.prefix(2)).uppercased()
    }

    static func store(_ p: MemberProfile?) {
        let name = p.map(realName) ?? ""
        let d = UserDefaults.standard
        if name.isEmpty { d.removeObject(forKey: nameKey); d.removeObject(forKey: initialsKey) }
        else { d.set(name, forKey: nameKey); d.set(initials(name), forKey: initialsKey) }
    }

    /// What the face's tooltip says: the name, else "User".
    static var tipName: String {
        let n = UserDefaults.standard.string(forKey: nameKey) ?? ""
        return n.isEmpty ? "User" : n
    }

    /// The person's photo, else the initials on their own palette colour (App/Settings/AvatarViews.swift).
    var body: some View {
        PersonFace(initials: initials.isEmpty ? "U" : initials, size: size, scale: 0.45)
    }
}

/// The marks on a bubble: emoji + faces, small, on the bubble's bottom row left of the time (inside
/// the bubble, never under it;: at the row's left end, the time stays right, the chip a bit bigger).
/// The person's own chip is tinted; a click on it takes the reaction back, a click on someone else's reacts with the
/// same emoji (as in Telegram). `onToggle(e)` turns `e` on or off.
struct ChatReactionChips: View {
    let reactions: [ChatReaction]
    /// On the person's blue bubble.
    var onDark = false
    let onToggle: (String) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(reactions) { r in chip(r) }
        }
    }

    private func chip(_ r: ChatReaction) -> some View {
        Button { onToggle(r.emoji) } label: {
            HStack(spacing: 3) {
                Text(r.emoji).font(.system(size: 13))
                HStack(spacing: -5) {
                    ForEach(r.reactors.prefix(3)) { p in
                        face(p).overlay(Circle().stroke(ring(r), lineWidth: 1))
                    }
                }
                if r.reactors.count > 3 {
                    Text("+\(r.reactors.count - 3)").font(LiaFont.ui(9.5, .semibold))
                        .foregroundStyle(onDark ? Color.white.opacity(0.8) : WS.text2).monospacedDigit()
                }
            }
            // The emoji keeps its size; the faces (16 -> 20) and the capsule (18 -> 24) grow.
            .padding(.leading, 6).padding(.trailing, 2).frame(height: 24)
            .background(fill(r), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain).liaPointer()
        .accessibilityLabel(Text(label(r)))
        .accessibilityHint(Text(r.mine ? "Removes your reaction" : "Reacts with the same"))
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private func fill(_ r: ChatReaction) -> Color {
        if onDark { return Color.white.opacity(r.mine ? 0.22 : 0.14) }
        return r.mine ? WS.blue.opacity(0.14) : WS.ink.opacity(0.06)
    }

    private func ring(_ r: ChatReaction) -> Color {
        onDark ? Color(hex: 0x4A66FE) : (r.mine ? Color.dyn(0x2A3150, 0xE3E8FF) : WS.soft)
    }

    @ViewBuilder private func face(_ p: ChatReactor) -> some View {
        if p.mine {
            ChatMeFace(size: 20)
        } else {
            Circle().fill(WS.text3).frame(width: 20, height: 20)
                .overlay(Text(p.initials).font(LiaFont.ui(9, .semibold)).foregroundStyle(Color.white)
                    .minimumScaleFactor(0.5).lineLimit(1))
        }
    }

    private func tip(_ r: ChatReaction) -> String {
        let who = r.mine ? ChatMeFace.tipName + " \u{00B7} " : ""
        if r.emoji == ChatLocal.heart { return who + (r.mine ? "Click to unlike" : "Like") }
        return who + (r.mine ? "Remove reaction" : "React with \(ChatReaction.name(r.emoji))")
    }

    private func label(_ r: ChatReaction) -> String {
        let who = r.mine ? (r.reactors.count == 1 ? "you" : "you and \(r.reactors.count - 1) more") : "\(r.reactors.count)"
        return "\(ChatReaction.name(r.emoji)), \(who)"
    }
}

/// The round heart beside a hovered bubble. A click likes the message (again: takes the like back); hovering it opens
/// the picker over it, growing upwards: \u{1F44E} and \u{1F44D} over the heart, which stays at the bottom where
/// the button was. It stays while the pointer is on the button or the picker (the row's own hover ends where the
/// picker leaves the row).
struct ChatReactButton: View {
    /// The message is liked (a favourite).
    let liked: Bool
    /// The person's thumb, nil = none.
    let thumb: String?
    /// The pointer is over the message: the button shows.
    let rowHover: Bool
    /// Turns the emoji on or off (❤️: the like; a thumb: replaces the other one).
    let onToggle: (String) -> Void
    @State private var overButton = false
    @State private var overPicker = false
    @State private var open = false
    @State private var hovered: String?
    @State private var pending: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var quick: String { ChatLocal.heart }
    private var shown: Bool { rowHover || overButton || open }

    var body: some View {
        Button { pick(quick) } label: {
            Text(quick).font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(WS.surface, in: Circle())
                .overlay(Circle().stroke(WS.line2, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain).liaPointer()
        .onHover { overButton = $0; hoverChanged() }
        .overlay(alignment: .bottom) {
            if open {
                picker
                    .offset(y: 8)
                    .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
        }
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityLabel(Text(liked ? "Unlike" : "Like"))
        .onDisappear { pending?.cancel() }
    }

    private var picker: some View {
        VStack(spacing: 2) {
            ForEach(ChatReaction.offered.reversed(), id: \.self) { e in
                Button { pick(e) } label: {
                    Text(e).font(.system(size: 22))
                        .frame(width: 34, height: 34)
                        .background(isOn(e) ? WS.blue.opacity(0.16) : Color.clear, in: Circle())
                        .scaleEffect(hovered == e ? 1.2 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovered)
                        .contentShape(Circle())
                }
                .buttonStyle(.liaPlain).liaPointer()
                .onHover { h in
                    if h { hovered = e } else if hovered == e { hovered = nil }
                }
                .accessibilityLabel(Text(isOn(e) ? (e == quick ? "Unlike" : "Remove \(ChatReaction.name(e)) reaction") : ChatReaction.name(e)))
                .accessibilityAddTraits(isOn(e) ? .isSelected : [])
            }
        }
        .padding(4)
        .background(WS.surface, in: Capsule())
        .overlay(Capsule().stroke(WS.line2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .fixedSize()
        .onHover { overPicker = $0; hoverChanged() }
    }

    private func isOn(_ e: String) -> Bool { e == quick ? liked : thumb == e }

    /// The same again takes it back; the other thumb replaces a thumb; the like and a thumb live side by side.
    private func pick(_ e: String) {
        onToggle(e)
        pending?.cancel()
        overPicker = false
        setOpen(false)
    }

    /// Opens the moment the pointer arrives (no delay), closes a moment after it leaves both (so the
    /// pointer can travel from the button to the picker without it folding).
    private func hoverChanged() {
        pending?.cancel()
        let want = overButton || overPicker
        guard want != open else { return }
        if want { setOpen(true); return }
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let now = overButton || overPicker
            if now != open { setOpen(now) }
        }
    }

    private func setOpen(_ on: Bool) {
        if reduceMotion { open = on } else { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { open = on } }
        if !on { hovered = nil }
    }
}
