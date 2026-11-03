import SwiftUI

// A workspace's quick settings in a popover at its pill (right-click, or the chevron on hover):
// rename, its colour, and the full settings.: its ad accounts are shown and changed only in Workspace
// Settings, never here.

struct WorkspaceQuickSettings: View {
    @ObservedObject var ws: WorkspaceModel
    let profile: CompanyProfile
    let close: () -> Void
    @State private var name: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(ws: WorkspaceModel, profile: CompanyProfile, close: @escaping () -> Void) {
        self.ws = ws
        self.profile = profile
        self.close = close
        _name = State(initialValue: profile.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !saving && !trimmed.isEmpty && trimmed != profile.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            nameField
            colours
            Divider()
            shareButtons
            settingsButton
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Workspace \(profile.name) settings"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            WorkspaceAvatar(profile: profile, name: trimmed.isEmpty ? profile.name : trimmed, size: 24)   // Its picture when it has one
            Text("Workspace").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Name").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
            HStack(spacing: 6) {
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .font(LiaFont.ui(13))
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(WS.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityLabel(Text("Workspace name"))
                Button(saving ? "Saving\u{2026}" : "Rename", action: save)
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(!canSave)
                    .liaPointer()
            }
            if let error {
                Text(error).font(LiaFont.ui(11.5)).foregroundStyle(WS.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The workspace's colour (pill, monogram, load bar, tab group tint).
    private var colours: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colour").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
            HStack(spacing: 7) {
                ForEach(CompanyProfile.palette, id: \.self) { c in swatch(c) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Workspace colour"))
            .accessibilityValue(Text(CompanyProfile.palette.contains(profile.colorHex) ? "colour \((CompanyProfile.palette.firstIndex(of: profile.colorHex) ?? 0) + 1) of \(CompanyProfile.palette.count)" : "custom"))
        }
    }

    private func swatch(_ c: UInt32) -> some View {
        Button {
            guard c != profile.colorHex else { return }
            let p = profile, w = ws
            Task { _ = await w.updateProfile(p, name: p.name, color: c) }
        } label: { swatchFace(c) }
        .buttonStyle(.liaPlain)
        .liaPointer()
    }

    private func swatchFace(_ c: UInt32) -> some View {
        let current = c == profile.colorHex
        return Circle().fill(Color(hex: c))
            .frame(width: 20, height: 20)
            .overlay {
                if current {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                }
            }
            .overlay(Circle().stroke(current ? WS.ink.opacity(0.35) : Color.clear, lineWidth: 2).padding(-3))
            .opacity(current ? 1 : 0.75)
    }

    /// Hand the workspace's tabs to a colleague as a file, or open theirs here.
    private var shareButtons: some View {
        HStack(spacing: 8) {
            Button("Share Tabs\u{2026}") {
                close()
                let b = ws.browser(for: profile), n = profile.name, w = ws
                // the panel runs once the popover is gone, not modal over it
                Task { @MainActor in WorkspaceShare.export(b, name: n, ws: w) }
            }
            Button("Import Tabs\u{2026}") {
                close()
                let b = ws.browser(for: profile), w = ws
                Task { @MainActor in WorkspaceShare.importTabs(into: b, ws: w) }
            }
        }
        .buttonStyle(WSButtonStyle(small: true))
    }

    private var settingsButton: some View {
        Button {
            close()
            ws.editingProfile = profile
        } label: {
            HStack {
                Text("Workspace Settings\u{2026}").font(LiaFont.ui(13)).foregroundStyle(WS.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text3)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 8)
        .accessibilityLabel(Text("Workspace Settings"))
    }

    private func save() {
        guard canSave else { return }
        let n = trimmed
        saving = true
        error = nil
        Task { @MainActor in
            let e = await ws.updateProfile(profile, name: n)
            saving = false
            if let e { error = e; return }
            ws.show("Renamed to \(n)", symbol: "pencil")
            close()
        }
    }
}
