import SwiftUI

/// A workspace's settings (or a new one): its name and, 12, the Meta ad accounts added to it;
/// And the GitHub repositories Dev works in (WorkspaceReposSection).
/// The workspace is the base; ad accounts are additions the person picks from their Meta ad accounts.
struct NewProfileSheet: View {
    @ObservedObject var ws: WorkspaceModel
    /// Set: edit this profile (rename, its ad accounts) instead of making one.
    var editing: CompanyProfile? = nil
    @Environment(\.liaDismiss) private var dismiss
    @State private var name = ""
    /// The workspace's ad accounts as edited here (saved with Save).
    @State private var accounts: [(id: String, name: String)] = []
    /// The GitHub repositories Dev works in here, as edited (saved with Save).
    @State private var repos: [WorkspaceRepo] = []
    /// The "Add ad account" list is open, and what is ticked in it.
    @State private var picking = false
    @State private var pick: Set<String> = []
    @State private var error: String?
    @State private var saving = false
    /// Default accounts on this Mac (WorkspaceAccounts): Google services and Ads Manager open on them.
    @State private var google = ""
    /// Google accounts signed in in this workspace's browser (GoogleSignedIn); nil: still reading.
    @State private var googleList: [GoogleAccount]?
    @State private var googleFresh = true
    /// The business that owns the ad account, from the ad account data (MetaBusiness); nil: unknown, cell hidden.
    @State private var business: MetaBusiness.Owner?
    /// Google could not be asked and nothing was seen before (not "nobody signed in").
    @State private var googleFailed = false
    /// The sign-in cookies the list was read with; a change re-reads it (GoogleSignedIn.cookiesChanged).
    @State private var googlePrint: String?
    @State private var googleRecheck: Task<Void, Never>?
    /// The workspace's colour as chosen here (saved with Save) and, for a new workspace, the picture
    /// picked before it exists (uploaded once it is made).
    @State private var color: UInt32 = CompanyProfile.palette[0]
    @State private var pendingPicture: NSImage?
    @ObservedObject private var avatars = AvatarStore.shared

    /// The first ad account: Ads Manager and the Meta reads open on it.
    private var account: String { accounts.first?.id ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "New workspace" : "Workspace settings").font(LiaFont.ui(19, .bold)).foregroundStyle(WS.ink)
            Text("A workspace has its own browser, sign-ins and agents. Add the ad accounts it works on.")
                .font(LiaFont.ui(13)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
            identity
            adAccountsSection
            WorkspaceReposSection(repos: $repos, auth: ws.auth)
            defaultAccounts
            if let error { Text(error).font(LiaFont.ui(12.5)).foregroundStyle(WS.bad) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(WSButtonStyle())
                Button(saving ? "Saving\u{2026}" : (editing == nil ? "Create" : "Save")) { create() }
                    .buttonStyle(WSButtonStyle(primary: true))
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let p = editing {
                name = p.name; accounts = p.metaAccounts; repos = p.githubRepos
                google = WorkspaceAccounts.google(p.id) ?? ""
                color = p.colorHex
            } else {
                color = CompanyProfile.palette[ws.profiles.count % CompanyProfile.palette.count]   // createProfile's pick
            }
            // A locked agent or "New workspace" sent the person here: the account list opens.
            if ws.settingsFocus == "accounts" { ws.settingsFocus = nil; if ws.metaConnected { picking = true } }
        }
        .task { await loadAccounts() }
        // Signed in (or out) in the workspace's browser while this is open: read the list again.
        .onReceive(NotificationCenter.default.publisher(for: GoogleSignedIn.cookiesChanged)) { n in
            guard let k = n.object as? String, k == googleBrowserKey else { return }
            googleRecheck?.cancel()
            googleRecheck = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, await GoogleSignedIn.fingerprint(browserKey: k) != googlePrint else { return }
                await loadGoogle()
            }
        }
        .onDisappear { googleRecheck?.cancel() }
    }

    // MARK: picture, name, colour

    /// The top of the sheet: the workspace's picture on the left (hover: a camera; a click: the picker), its name and
    /// colour to the right.
    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            face
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2)
                TextField("Acme Studio \u{00b7} Autumn", text: $name)
                    .textFieldStyle(.plain).font(LiaFont.ui(14))
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 7) {
                    ForEach(CompanyProfile.palette, id: \.self) { c in swatch(c) }
                }
                .padding(.top, 4).padding(.leading, 3)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Workspace colour"))
            }
        }
    }

    private var shownName: String {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? (editing?.name ?? "") : t
    }

    private var pictureWho: AvatarWho? { editing.map { .workspace($0.id) } }

    @ViewBuilder private var face: some View {
        let busy = pictureWho.map { avatars.busy.contains($0.id) } ?? false
        let has = editing.map { avatars.workspaces[$0.id] != nil } ?? (pendingPicture != nil)
        AvatarEditButton(size: 64, busy: busy, hasPicture: has, label: "Change the workspace\u{2019}s picture",
                         pick: pickPicture, remove: removePicture) {
            if let p = editing {
                WorkspaceAvatar(profile: p, name: shownName, colorHex: color, size: 64)
            } else if let img = pendingPicture {
                Image(nsImage: img).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
            } else {
                WSMonogram(name: shownName.isEmpty ? "?" : shownName, colorHex: color, size: 64)
            }
        }
    }

    private func pickPicture() {
        guard let who = pictureWho else { pendingPicture = AvatarPicture.pick() ?? pendingPicture; return }
        let a = ws.auth
        Task { if let e = await AvatarStore.shared.pickAndSet(who, auth: a) { error = e } }
    }

    private func removePicture() {
        guard let who = pictureWho else { pendingPicture = nil; return }
        let a = ws.auth
        Task { if let e = await AvatarStore.shared.remove(who, auth: a) { error = e } }
    }

    private func swatch(_ c: UInt32) -> some View {
        let current = c == color
        return Button { color = c } label: {
            Circle().fill(Color(hex: c))
                .frame(width: 18, height: 18)
                .overlay {
                    if current { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.white) }
                }
                .overlay(Circle().stroke(current ? WS.ink.opacity(0.35) : Color.clear, lineWidth: 2).padding(-3))
                .opacity(current ? 1 : 0.75)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text("Colour \((CompanyProfile.palette.firstIndex(of: c) ?? 0) + 1)"))
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    // MARK: ad accounts

    /// The person's Meta ad accounts not yet in this workspace.
    private var addable: [AdAccount] {
        ws.adAccounts.filter { a in !accounts.contains { $0.id == (CompanyProfile.digits(a.id) ?? a.id) } }
    }

    private var adAccountsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ad accounts").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2)
            if !accounts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Rectangle().fill(WS.line).frame(height: 1) }
                        accountRow(a)
                    }
                }
                .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line, lineWidth: 1))
            }
            if !ws.metaConnected {
                HStack(spacing: 8) {
                    Text("Connect Meta to add ad accounts").font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
                    Spacer(minLength: 8)
                    Button("Connect") { MetaConnect.open(auth: ws.auth, ws: ws) }.buttonStyle(WSButtonStyle(small: true))
                }
            } else if picking {
                picker
            } else if !addable.isEmpty && accounts.count < 20 {
                Button { pick = []; picking = true } label: {
                    Label("Add ad account", systemImage: "plus").font(LiaFont.ui(13, .medium))
                }
                .buttonStyle(WSButtonStyle(small: true))
            } else if accounts.isEmpty {
                Text("No ad accounts found in Meta yet.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            }
        }
    }

    private func accountRow(_ a: (id: String, name: String)) -> some View {
        HStack(spacing: 8) {
            Text(a.name.isEmpty ? a.id : a.name).font(LiaFont.ui(13.5)).foregroundStyle(WS.ink).lineLimit(1)
            Text(a.id).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1).monospacedDigit()
            Spacer(minLength: 8)
            Button { accounts.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .accessibilityLabel(Text("Remove \(a.name.isEmpty ? a.id : a.name)"))
        }
        .padding(.horizontal, 12).frame(height: 36)
    }

    /// The person's other ad accounts, a checkbox each; Add puts the ticked ones in the list above.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if addable.isEmpty {
                Text("Every ad account is in this workspace.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(addable.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Rectangle().fill(WS.line).frame(height: 1) }
                            pickRow(a)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: addable.count < 6)
                .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { picking = false }.buttonStyle(WSButtonStyle(small: true))
                Button(pick.count > 1 ? "Add \(pick.count)" : "Add") { addPicked() }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(pick.isEmpty)
            }
        }
    }

    private func pickRow(_ a: AdAccount) -> some View {
        let on = pick.contains(a.id)
        return Button { if on { pick.remove(a.id) } else { pick.insert(a.id) } } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(on ? WS.blue : WS.text3)
                Text(a.name.isEmpty ? a.id : a.name).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(CompanyProfile.digits(a.id) ?? a.id).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text(a.name.isEmpty ? a.id : a.name))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func addPicked() {
        for a in ws.adAccounts where pick.contains(a.id) {
            guard let d = CompanyProfile.digits(a.id), !accounts.contains(where: { $0.id == d }), accounts.count < 20 else { continue }
            accounts.append((d, a.name))
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let f = accounts.first { name = f.name }
        pick = []
        picking = false
    }

    private func create() {
        saving = true
        error = nil
        Task {
            let n = name.trimmingCharacters(in: .whitespaces)
            let e: String?
            if let p = editing {
                e = await ws.updateProfile(p, name: n, accounts: accounts, color: color != p.colorHex ? color : nil, repos: repos)
            } else {
                e = await ws.createProfile(name: n, accounts: accounts, repos: repos)
                // The colour and the picture chosen before the workspace existed.
                if e == nil, let made = ws.profiles.first(where: { $0.id == ws.profileId }) {
                    if color != made.colorHex { _ = await ws.updateProfile(made, name: made.name, color: color) }
                    if let img = pendingPicture { _ = await AvatarStore.shared.set(.workspace(made.id), image: img, auth: ws.auth) }
                }
            }
            saving = false
            if let e { error = e; return }
            // A new workspace is the selected one once made.
            if let pid = editing?.id ?? ws.profileId {
                WorkspaceAccounts.setGoogle(google, pid)
                // Derived from the ad account, never typed: unknown (or no Meta) clears it.
                WorkspaceAccounts.setBusiness(showsMeta ? business?.id : nil, pid)
            }
            dismiss()
        }
    }

    /// The Google accounts of this workspace's browser and the business that owns its ad account. A new workspace has
    /// no browser yet: the one in front is read (Google sign-ins are shared by every workspace, SharedSignIns).
    private func loadAccounts() async {
        await loadGoogle()
        if ws.meta == nil { await ws.refreshMeta() }
        await loadBusiness()
        if editing != nil { await AvatarStore.shared.refresh(auth: ws.auth) }   // The picture set elsewhere
    }

    /// The browser whose Google sign-ins are listed: this workspace's, or (a new one) the one in front.
    private var googleBrowserKey: String? {
        (editing?.id ?? ws.profileId).map { CompanyProfile.browserKey(account: ws.auth.activeId, profile: $0) }
    }

    private func loadGoogle() async {
        if let key = googleBrowserKey {
            let r = await GoogleSignedIn.list(browserKey: key)
            googleList = r?.accounts ?? []
            googleFresh = r?.fresh ?? true
            googleFailed = r == nil
            googlePrint = r?.fingerprint ?? ""
        } else {
            googleList = []
        }
        let saved = editing.flatMap { WorkspaceAccounts.google($0.id) } ?? google
        if let g = GoogleAccounts.preselect(saved: saved, signedIn: googleList ?? []) { google = g }
    }

    private func loadBusiness() async {
        let acc = account.filter(\.isNumber)
        guard !acc.isEmpty, ws.metaLive != false,
              let data = await LiaAPI(auth: ws.auth).authorizedData(AppConfig.mcpBase + "/call/list_ad_accounts") else {
            business = nil; return
        }
        business = MetaBusiness.owner(of: acc, in: data)
    }

    /// The Meta cell: Meta connected, the workspace on an ad account and its owning business known.
    private var showsMeta: Bool { ws.metaLive != false && !account.isEmpty && business != nil }

    /// Google account (a signed-in one, picked from a list) and the Meta business (read-only).
    private var defaultAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            googleCard
            if showsMeta, let b = business { metaCard(b) }
            Text(showsMeta ? "Google services and Ads Manager open on these accounts in this workspace."
                           : "Google services open on this account in this workspace.")
                .font(LiaFont.ui(12)).foregroundStyle(WS.text3).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: account) { _, _ in Task { await loadBusiness() } }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WS.line, lineWidth: 1))
    }

    private var googleCard: some View {
        card {
            Text("Google account").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2)
            if googleList == nil {
                Text("Reading the accounts signed in\u{2026}").font(LiaFont.ui(13)).foregroundStyle(WS.text3).frame(height: 38)
            } else if let list = googleList, !list.isEmpty {
                googleDropdown(list)
                if !googleFresh {
                    Text("Couldn\u{2019}t reach Google. These are the accounts seen before.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                }
            } else {
                if !google.isEmpty { Text(google).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(1) }
                Text(googleFailed ? "Couldn\u{2019}t reach Google to read the accounts signed in. Open this again in a moment."
                                  : "Sign in to Google in this workspace\u{2019}s browser to choose an account.")
                    .font(LiaFont.ui(12)).foregroundStyle(WS.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only the accounts signed in in this browser: no free text (17).
    private func googleDropdown(_ list: [GoogleAccount]) -> some View {
        DropdownButton(radius: 12, highlight: false) {
            HStack(spacing: 8) {
                Text(google.isEmpty ? "Choose an account" : google).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .bold)).foregroundStyle(WS.text2)
            }
            .padding(.horizontal, 12).frame(width: 384, height: 38)
            .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } menu: {
            DropdownPanelView(width: 384) {
                ForEach(list, id: \.email) { a in
                    DropdownItem(title: a.name.isEmpty ? a.email : a.name + " \u{00b7} " + a.email,
                                 trailing: google.lowercased() == a.email.lowercased() ? "check" : nil, fontSize: 13) { google = a.email }
                }
            }
        }
        .accessibilityLabel(Text("Google account"))
        .accessibilityValue(Text(google))
    }

    /// Fixed: the business that owns the workspace's ad account. Nothing to change here.
    private func metaCard(_ b: MetaBusiness.Owner) -> some View {
        card {
            Text("Meta Business").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2)
            HStack(spacing: 8) {
                if let n = b.name, !n.isEmpty { Text(n).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(1) }
                Text(b.id).font(LiaFont.ui(13)).foregroundStyle(WS.text2).textSelection(.enabled)
                Spacer(minLength: 0)
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(WS.text3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Meta Business ID \(b.id), fixed"))
        }
    }
}

/// Every change the agents made in this client's ad account, newest first. Undo goes through Met (she prepares
/// the undo, the person says Yes), so an undo is itself a change in the journal.
/// Filtered by who made the change, grouped by day. (item 14): the desktop's "Relay" is this
/// journal, one per workspace, no folders; compact rows in a lazy list, sized to its rows (no empty 460 pt box).
struct JournalSheet: View {
    @ObservedObject var ws: WorkspaceModel
    @Environment(\.liaDismiss) private var dismiss
    /// The agent whose changes show (nil: everyone's).
    @State private var who: String?

    var body: some View {
        let authors = JournalDays.authors(ws.journal)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Journal").font(LiaFont.ui(17, .bold)).foregroundStyle(WS.ink).accessibilityAddTraits(.isHeader)
                Text(ws.profile?.name ?? "").font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(1)
                Spacer(minLength: 8)
                if authors.count > 1 { authorPicker(authors) }
                Button("Close") { dismiss() }.buttonStyle(WSButtonStyle(small: true))
            }
            if ws.journal.isEmpty {
                Text("No changes in this workspace yet.").font(LiaFont.ui(13)).foregroundStyle(WS.text3).padding(.vertical, 8)
            } else {
                list
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
        .frame(width: 560)
        // One journal per workspace: switching workspace reads that one.
        .task(id: ws.profileId) { await ws.loadJournal() }
        .onChange(of: ws.profileId) { _, _ in who = nil }
    }

    /// Who made the changes, in our glass dropdown (not the system pop-up menu).
    private func authorPicker(_ authors: [String]) -> some View {
        DropdownButton(align: .trailing, radius: 12, highlight: false) {
            HStack(spacing: 6) {
                Text(who ?? "All agents").font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.ink)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WS.text2)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } menu: {
            DropdownPanelView {
                DropdownItem(title: "All agents", trailing: who == nil ? "check" : nil, fontSize: 13) { who = nil }
                ForEach(authors, id: \.self) { a in
                    DropdownItem(title: a, trailing: who == a ? "check" : nil, fontSize: 13) { who = a }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(Text("Show changes by"))
        .accessibilityValue(Text(who ?? "All agents"))
    }

    private var list: some View {
        let days = JournalDays.group(ws.journal, by: who)
        // Height from the rows (30 pt each, 26 per day header), up to 520: a short journal is a short sheet.
        let rows = days.reduce(0) { $0 + $1.rows.count }
        let height = min(520, CGFloat(rows) * 31 + CGFloat(days.count) * 26 + 4)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    Section {
                        ForEach(Array(day.rows.enumerated()), id: \.offset) { _, row in
                            JournalRow(row: row) { undo(row) }
                        }
                    } header: {
                        Text(day.label).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 26, alignment: .bottomLeading)
                            .padding(.bottom, 2)
                            .background(WS.surface)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if days.isEmpty {
                    Text("No changes by \(who ?? "this agent").").font(LiaFont.ui(13)).foregroundStyle(WS.text3).padding(.vertical, 8)
                }
            }
        }
        .frame(height: days.isEmpty ? 40 : height)
    }

    private func undo(_ row: JSONObject) {
        let what = [JSONRead.string(row, "tool"), JSONRead.string(row, "entity")].compactMap { $0 }.joined(separator: " \u{00b7} ")
        let id = JSONRead.string(row, "id") ?? ""
        dismiss()
        let ws = self.ws
        ws.send("Undo this change: \(what) (journal \(id)).", toAgent: "met")
    }
}

/// The journal's authors ("by") and its rows by day (Today, Yesterday, Oct 9), newest first.
enum JournalDays {
    struct Day { let label: String; var rows: [JSONObject] }

    static func author(_ row: JSONObject) -> String? {
        let b = (JSONRead.string(row, "by") ?? "").trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? nil : b
    }

    static func authors(_ rows: [JSONObject]) -> [String] {
        var seen: [String] = []
        for r in rows { if let a = author(r), !seen.contains(a) { seen.append(a) } }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func group(_ rows: [JSONObject], by who: String?) -> [Day] {
        let cal = Calendar.current
        var out: [Day] = []
        for r in rows where who == nil || author(r) == who {
            let label = dayLabel(JSONRead.double(r, "ts").map { Date(timeIntervalSince1970: $0 / 1000) }, cal: cal)
            if let last = out.last, last.label == label {
                out[out.count - 1].rows.append(r)
            } else {
                out.append(Day(label: label, rows: [r]))
            }
        }
        return out
    }

    private static func dayLabel(_ d: Date?, cal: Calendar) -> String {
        guard let d else { return "Earlier" }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct JournalRow: View {
    let row: JSONObject
    let onUndo: () -> Void
    @State private var hover = false

    /// One formatter for every row (a new DateFormatter per row per redraw made the list lag).
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"   // The day is the section's
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Text(when).font(LiaFont.ui(11.5)).monospacedDigit().foregroundStyle(WS.text3).frame(width: 38, alignment: .leading)
            Text(JSONRead.string(row, "entity") ?? "\u{2014}").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                .layoutPriority(1)
            Text([JSONRead.string(row, "tool"), JSONRead.string(row, "by")].compactMap { $0 }.joined(separator: " \u{00b7} "))
                .font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
            Spacer(minLength: 6)
            if JSONRead.bool(row, "undone") {
                Text("undone").font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
            } else if JSONRead.bool(row, "undo") {
                Button("Undo", action: onUndo).buttonStyle(WSButtonStyle(small: true))
                    .opacity(hover ? 1 : 0.75)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 31)
        .background(hover ? WS.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }

    private var when: String {
        guard let ms = JSONRead.double(row, "ts") else { return "" }
        return Self.clock.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
