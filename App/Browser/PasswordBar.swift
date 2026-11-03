import SwiftUI
import AppKit

// The password manager's chrome: the key in the address bar with its accounts popover (and Command-Backslash), and
// the glass bar under the address bar that offers to save. The logic is TabPasswords (PasswordTab.swift).

/// The key in the selected tab's address field: shown while the page has a sign-in form and this workspace has
/// accounts for the site (or the page is http, which gets a warning and no fill).
struct PasswordKeyButton: View {
    @ObservedObject var pw: TabPasswords
    /// False on a narrow tab (TabButtons.showsKey): no glyph, Command-Backslash still fills.
    var glyphShown = true
    @ObservedObject private var store = PasswordStore.shared
    @Environment(\.wsBarOnDark) private var onDark

    var body: some View {
        if pw.showsKey && !glyphShown {
            shortcut
        } else if pw.showsKey {
            Button { pw.popoverOpen.toggle() } label: { glyph }
                .buttonStyle(.liaPlain)
                .liaHover(.icon, radius: 6)
                .popover(isPresented: $pw.popoverOpen, arrowEdge: .bottom) { PasswordPopover(pw: pw) }
                .background(shortcut)
                .accessibilityLabel(Text(pw.insecure ? "Passwords: this page is not secure" : "Fill a saved password"))
        }
    }

    private var glyph: some View {
        Image(systemName: "key.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(pw.insecure ? Color.orange : BarInk.text2(onDark))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    /// Command-Backslash fills the first account (the one the popover lists first).
    private var shortcut: some View {
        Button("") { Task { await pw.fillFirst() } }
            .keyboardShortcut("\\", modifiers: [.command])
            .buttonStyle(.liaPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .disabled(pw.insecure)
    }
}

/// The accounts for the page: this host's, then the same site's. A click asks for Touch ID and fills.
struct PasswordPopover: View {
    @ObservedObject var pw: TabPasswords

    var body: some View {
        let m = pw.matches
        VStack(alignment: .leading, spacing: 6) {
            Text("Passwords").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text3)
                .padding(.horizontal, 8)
            if pw.insecure {
                PasswordInsecureNote()
            } else {
                ForEach(m.exact) { item in PasswordAccountRow(item: item) { Task { await pw.fill(item) } } }
                if !m.related.isEmpty { relatedHeader }
                ForEach(m.related) { item in PasswordAccountRow(item: item) { Task { await pw.fill(item) } } }
            }
            if let n = pw.notice {
                Text(n).font(LiaFont.ui(11.5)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            }
            Divider().padding(.vertical, 2)
            Button("Passwords Settings\u{2026}") { Self.openSettings(); pw.popoverOpen = false }
                .buttonStyle(.liaPlain)
                .font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .liaHover(.fill, radius: 6)
        }
        .padding(10)
        .frame(width: 290, alignment: .leading)
    }

    private var relatedHeader: some View {
        Text("Other accounts on " + PasswordMatch.registrableDomain(pw.pageHost ?? ""))
            .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
            .padding(.horizontal, 8).padding(.top, 6)
    }

    static func openSettings() {
        if let u = URL(string: "liaison://settings/passwords") { NSWorkspace.shared.open(u) }
    }
}

private struct PasswordInsecureNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).font(.system(size: 12))
            Text("This page is not secure (http). Liaison does not fill passwords here: anyone on the network could read them.")
                .font(LiaFont.ui(12)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

struct PasswordAccountRow: View {
    let item: PasswordItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 18)).foregroundStyle(WS.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.user.isEmpty ? "No user name" : item.user).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                    Text(item.site).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 7)
        .accessibilityLabel(Text("Fill " + (item.user.isEmpty ? item.site : item.user)))
    }
}

/// The accounts under the focused sign-in field (a native popover anchored at the field,
/// TabPasswords.showSuggestions): this host's, then the same site's. A pick asks for Touch ID and fills both fields;
/// nothing is submitted.
struct PasswordFieldSuggestions: View {
    @ObservedObject var pw: TabPasswords
    @ObservedObject private var store = PasswordStore.shared

    var body: some View {
        let m = pw.matches
        VStack(alignment: .leading, spacing: 2) {
            ForEach(m.exact) { item in PasswordAccountRow(item: item) { pw.pickSuggestion(item) } }
            if !m.related.isEmpty {
                Text("Other accounts on " + PasswordMatch.registrableDomain(pw.pageHost ?? ""))
                    .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                    .padding(.horizontal, 8).padding(.top, 4)
                ForEach(m.related) { item in PasswordAccountRow(item: item) { pw.pickSuggestion(item) } }
            }
            Divider().padding(.vertical, 2)
            Button("Passwords Settings\u{2026}") { pw.hideSuggestions(); PasswordPopover.openSettings() }
                .buttonStyle(.liaPlain)
                .font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .liaHover(.fill, radius: 6)
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Saved passwords for this page"))
    }
}

/// "Save password for site.com?" in glass under the address bar, after a sign-in went through.
struct PasswordBar: View {
    @ObservedObject var pw: TabPasswords

    var body: some View {
        if let o = pw.offer {
            PasswordOfferCard(offer: o, pw: pw)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct PasswordOfferCard: View {
    let offer: TabPasswords.Offer
    let pw: TabPasswords

    private var question: String {
        offer.update ? "Update password for \(offer.site)?" : "Save password for \(offer.site)?"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.ink)
                .frame(width: 28, height: 28)
                .background(WS.soft, in: Circle())
            texts
            Spacer(minLength: 12)
            buttons
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 8)
        .frame(maxWidth: 600)
        .wsGlass(16)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(question))
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(question).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
            Text(offer.user.isEmpty ? "Saved in this workspace only, in your Mac\u{2019}s Keychain." : offer.user)
                .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Not Now") { pw.dismissOffer() }
                .buttonStyle(WSButtonStyle(small: true))
            if !offer.update {
                Button("Never for This Site") { pw.neverOffer() }
                    .buttonStyle(WSButtonStyle(small: true))
            }
            Button(offer.update ? "Update" : "Save") { pw.saveOffer() }
                .buttonStyle(WSButtonStyle(primary: true, small: true))
        }
        .fixedSize()
    }
}
