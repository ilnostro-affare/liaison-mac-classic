import SwiftUI
import AppKit

/// Workspace Settings > Repositories: the GitHub repositories Dev works in for this workspace (profile
/// `github_repos`, at most 20). Edited here and saved with the sheet's Save, with the rest of the workspace.
/// GitHub itself is connected once for the app (GitHubLink; Settings > Integrations > GitHub).
struct WorkspaceReposSection: View {
    @Binding var repos: [WorkspaceRepo]
    let auth: AuthStore
    @ObservedObject private var link = GitHubLink.shared
    @State private var picking = false
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Add sits on the title line, not under the list - a pick in the open picker adds a row
            // to the list, and a button below it moved down and took the popover with it (the jump).
            HStack(spacing: 8) {
                Text("Repositories").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2)
                Spacer(minLength: 8)
                if link.status?.connected == true { addButton }
            }
            Text("Dev works in these repositories for this workspace.")
                .font(LiaFont.ui(12)).foregroundStyle(WS.text3).fixedSize(horizontal: false, vertical: true)
            if !repos.isEmpty { list }
            if link.status?.connected != true, link.status != nil || tried {
                connectRow
            }
            if let e = link.error { Text(e).font(LiaFont.ui(12)).foregroundStyle(WS.bad) }
        }
        .task {
            await link.refresh(auth)
            tried = true
            // Read ahead: the picker opens on the list (and the lock on a private repository is known from it).
            if link.status?.connected == true { await link.loadRepos(auth) }
        }
    }

    private var addButton: some View {
        let full = repos.count >= WorkspaceRepo.limit
        return Button {
            Task { await link.loadRepos(auth) }
            picking = true
        } label: {
            Label("Add repository", systemImage: "plus").font(LiaFont.ui(13, .medium))
        }
        .buttonStyle(WSButtonStyle(small: true))
        // Kept while the picker is open (a button that went away at 20 would take the popover with it).
        .disabled(full && !picking)
        .liaTip(full ? "At most \(WorkspaceRepo.limit) repositories" : nil)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            RepoPicker(repos: $repos, open: $picking, auth: auth)
        }
    }

    private var connectRow: some View {
        HStack(spacing: 8) {
            if link.pending {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub\u{2026}").font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                Button("Cancel") { link.cancel() }
                    .buttonStyle(.liaPlain).font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.blue).liaPointer()
                Spacer(minLength: 8)
            } else {
                Text("Connect GitHub to add repositories.").font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
                Spacer(minLength: 8)
                Button(link.busy ? "Opening\u{2026}" : "Connect GitHub") { Task { await link.connect(auth) } }
                    .buttonStyle(WSButtonStyle(small: true))
                    .disabled(link.busy)
            }
        }
    }

    private var list: some View {
        // Up to 20: past five rows it scrolls, so the sheet keeps its height.
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(repos.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Rectangle().fill(WS.line).frame(height: 1) }
                    row(r)
                }
            }
        }
        .frame(maxHeight: 186)
        .fixedSize(horizontal: false, vertical: repos.count <= 5)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line, lineWidth: 1))
    }

    private func row(_ r: WorkspaceRepo) -> some View {
        let isPrivate = link.repos?.first(where: { $0.fullName.lowercased() == r.id })?.isPrivate == true
        return HStack(spacing: 8) {
            Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(WS.text2)
            Text(r.fullName).font(LiaFont.ui(13.5)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
            if isPrivate {
                Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(WS.text3)
                    .accessibilityLabel(Text("Private"))
            }
            Spacer(minLength: 8)
            Button { repos.removeAll { $0.id == r.id } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .accessibilityLabel(Text("Remove \(r.fullName)"))
        }
        .padding(.horizontal, 12).frame(height: 36)
    }
}

/// The repositories the GitHub App can reach; a click adds one to the workspace (or takes it out again).
private struct RepoPicker: View {
    @Binding var repos: [WorkspaceRepo]
    @Binding var open: Bool
    let auth: AuthStore
    @ObservedObject private var link = GitHubLink.shared
    @State private var query = ""

    /// The list's place: the same height in every state (reading, error, empty, rows), so the popover opens at its
    /// size and does not resize when the rows arrive.
    static let listHeight: CGFloat = 288

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add repository").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
            TextField("Search repositories", text: $query)
                .textFieldStyle(.plain).font(LiaFont.ui(13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(link.repos?.isEmpty ?? true)
            content
                .frame(maxWidth: .infinity)
                .frame(height: Self.listHeight)
                .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Rectangle().fill(WS.line).frame(height: 1)
            HStack(spacing: 8) {
                if link.status?.manageURL != nil {
                    Button("Missing a repository? Choose more on GitHub") { link.openManage() }
                        .buttonStyle(.liaPlain).font(LiaFont.ui(12, .medium)).foregroundStyle(WS.blue).liaPointer()
                }
                Spacer(minLength: 8)
                Button("Done") { open = false }.buttonStyle(WSButtonStyle(primary: true, small: true))
            }
        }
        .padding(14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(WS.surface)
        // Read on every open: the section reads ahead (so rows are usually here at once); a list already shown stays
        // while it is read again (repositories chosen on GitHub since come in).
        .task { await link.loadRepos(auth, force: link.repos != nil) }
    }

    @ViewBuilder
    private var content: some View {
        if let all = link.repos {
            let shown = GitHubRepo.filter(all, query)
            if all.isEmpty {
                note("No repositories yet. Choose them on GitHub.")
            } else if shown.isEmpty {
                note("No repositories match.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { r in pickRow(r) }
                    }
                }
            }
        } else if let e = link.reposError, !link.reposLoading {
            VStack(spacing: 10) {
                Text(e).font(LiaFont.ui(12.5)).foregroundStyle(WS.bad)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await link.loadRepos(auth, force: true) } }.buttonStyle(WSButtonStyle(small: true))
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Reading: skeleton rows where the rows will be.
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    HStack(spacing: 9) {
                        Skel(width: 14, height: 14, radius: 3)
                        Skel(width: CGFloat([170, 220, 140, 200, 160, 190][i]), height: 11)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Reading your repositories"))
        }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(12.5)).foregroundStyle(WS.text3).multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickRow(_ r: GitHubRepo) -> some View {
        let w = WorkspaceRepo(r)
        let on = repos.contains { $0.id == w.id }
        let full = !on && repos.count >= WorkspaceRepo.limit
        return Button {
            if on { repos.removeAll { $0.id == w.id } } else { repos = WorkspaceRepo.adding([w], to: repos) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(on ? WS.blue : WS.text3)
                Text(r.fullName).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
                if r.isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(WS.text3)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .disabled(full)
        .opacity(full ? 0.5 : 1)
        .accessibilityLabel(Text(r.fullName + (r.isPrivate ? ", private" : "")))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
