import SwiftUI

/// Widgets inside an answer, the web blocks ported: the creative gallery, creative performance and leads.
/// Drawn in the popups' language: the UI font, small sentence-case labels, tabular figures,
/// square thumbnails sized to the thread, and a light "Open" link instead of a heavy bar.
struct BlockWidget: View {
    let block: ChatBlock
    let auth: AuthStore
    let onOpenCreatives: (CreativePerformance?, DateRange?, String?) -> Void
    let onOpenLeads: (LeadsSummary) -> Void
    let onOpenCreative: (CreativeStat, DateRange?, String?) -> Void

    var body: some View {
        if let perf = CreativePerformance.parse(block.raw) {
            CreativePerformanceWidget(perf: perf, auth: auth, onOpenAll: { onOpenCreatives(perf, perf.period, perf.account) },
                                      onOpen: { onOpenCreative($0, perf.period, perf.account) })
        } else if block.tool == "get_creatives", let gallery = CreativeGallery.parse(block.raw) {
            GalleryWidget(gallery: gallery, auth: auth, onOpen: { onOpenCreative($0, nil, nil) },
                          onOpenAll: { onOpenCreatives(nil, nil, nil) })
        } else if block.kind == "leads", let leads = LeadsSummary.parse(block.raw) {
            LeadsWidget(leads: leads, auth: auth, onOpen: { onOpenLeads(leads) })
        }
    }
}

/// The card every widget sits in: a title row (title, account, period) over the content, an Open link at the foot.
private struct WidgetShell<Content: View>: View {
    let title: String
    var account: String?
    var period: String?
    var openTitle: String? = nil
    var onOpen: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(LiaFont.ui(13, .semibold)).foregroundStyle(AppConfig.ink).lineLimit(1)
                if let account, !account.isEmpty {
                    Text(account).font(LiaFont.ui(11.5, .medium)).foregroundStyle(AppConfig.text2).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(AppConfig.surface2))
                }
                Spacer(minLength: 6)
                if let period { Text(period).font(LiaFont.ui(11.5).monospacedDigit()).foregroundStyle(AppConfig.text3).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            content
            if let openTitle, let onOpen {
                HStack {
                    WidgetOpenButton(title: openTitle, action: onOpen)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
            } else {
                Spacer(minLength: 0).frame(height: 12)
            }
        }
        // The workspace's in-chat card (white, 14, hairline, soft shadow).
        .modifier(ChatCardBackground())
    }
}

/// A creative as a uniform thumbnail: cropped to fill, a play mark on a video, an optional rank badge.
struct CreativeThumb: View {
    let stat: CreativeStat
    let auth: AuthStore
    var width: CGFloat = 72
    var height: CGFloat = 72
    var rank: Int?
    var showName = false

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .background(AppConfig.surface2)
            .overlay {
                if let img = stat.image {
                    AuthedImage(url: img, auth: auth)
                } else {
                    LiaIcon("image", size: 16).foregroundStyle(AppConfig.text4)
                }
            }
            .overlay {
                if stat.isVideo {
                    LiaIcon("play-fill", size: 9).foregroundStyle(Color.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.black.opacity(0.45)))
                }
            }
            .overlay(alignment: .topLeading) {
                if let rank {
                    Text("\(rank)").font(LiaFont.ui(9.5, .bold).monospacedDigit()).foregroundStyle(Color.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showName {
                    Text(stat.name)
                        .font(LiaFont.ui(10, .medium)).foregroundStyle(Color.white).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                                                   startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppConfig.line, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

/// get_creatives: previews only, no numbers.
struct GalleryWidget: View {
    let gallery: CreativeGallery
    let auth: AuthStore
    let onOpen: (CreativeStat) -> Void
    let onOpenAll: () -> Void

    var body: some View {
        WidgetShell(title: "Creatives", openTitle: "Open creatives", onOpen: onOpenAll) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(gallery.items) { (c: CreativeStat) in
                        CreativeThumb(stat: c, auth: auth, width: 76, height: 76, showName: true)
                            .onTapGesture { onOpen(c) }
                            .liaPointer()
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

/// get_creative_analysis: the best creative, the ranked strip, the four numbers under it.
struct CreativePerformanceWidget: View {
    let perf: CreativePerformance
    let auth: AuthStore
    let onOpenAll: () -> Void
    let onOpen: (CreativeStat) -> Void

    var body: some View {
        WidgetShell(title: "Creative performance", account: perf.accountName, period: perf.period?.label,
                    openTitle: "Open creatives", onOpen: onOpenAll) {
            VStack(alignment: .leading, spacing: 12) {
                if let hero = perf.best { heroRow(hero) }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(perf.creatives.enumerated()), id: \.element.id) { i, c in
                            VStack(alignment: .leading, spacing: 4) {
                                CreativeThumb(stat: c, auth: auth, width: 56, height: 56, rank: c.rank ?? (i + 1))
                                Text(money(c.cpl)).font(LiaFont.ui(11.5, .semibold).monospacedDigit()).foregroundStyle(AppConfig.ink)
                                    .lineLimit(1)
                                Text(c.leads.map { "\($0) \($0 == 1 ? "lead" : "leads")" } ?? " ")
                                    .font(LiaFont.ui(10.5).monospacedDigit()).foregroundStyle(AppConfig.text3).lineLimit(1)
                            }
                            .frame(width: 56, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(c) }
                            .liaPointer()
                        }
                    }
                    .padding(.horizontal, 14)
                }

                HStack(spacing: 0) {
                    stat("Creatives", "\(perf.count)")
                    divider
                    stat("Avg CPL", money(perf.avgCPL))
                    divider
                    stat("Leads", perf.leads.map(String.init) ?? "\u{2014}")
                    divider
                    stat("Worst CPL", money(perf.worstCPL), bad: true)
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppConfig.surface2.opacity(0.7)))
                .padding(.horizontal, 14)
            }
        }
    }

    private func heroRow(_ hero: CreativeStat) -> some View {
        HStack(spacing: 10) {
            CreativeThumb(stat: hero, auth: auth, width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Best creative").font(LiaFont.ui(11, .medium)).foregroundStyle(AppConfig.accent)
                Text(hero.name).font(LiaFont.ui(13, .medium)).foregroundStyle(AppConfig.ink).lineLimit(1)
                if let ctx = hero.context {
                    Text(ctx).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(money(hero.cpl)).font(LiaFont.ui(15, .semibold).monospacedDigit()).foregroundStyle(AppConfig.ink)
                Text("cost per lead").font(LiaFont.ui(11)).foregroundStyle(AppConfig.text3)
            }
            .fixedSize()
        }
        // 0.2.11: the whole row opens the best creative (only its 44 pt thumbnail did; a click on its name did nothing).
        .clickable()
        .onTapGesture { onOpen(hero) }
        .padding(.horizontal, 14)
    }

    private var divider: some View {
        Rectangle().fill(AppConfig.line2).frame(width: 1, height: 24)
    }

    private func stat(_ label: String, _ value: String, bad: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label).font(LiaFont.ui(11)).foregroundStyle(AppConfig.text3).lineLimit(1)
            Text(value).font(LiaFont.ui(13, .semibold).monospacedDigit()).foregroundStyle(bad ? AppConfig.bad : AppConfig.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func money(_ v: Double?) -> String {
        guard let v else { return "\u{2014}" }
        let symbol = perf.currency == "USD" ? "$" : "\u{20ac}"
        return symbol + String(format: v < 10 ? "%.2f" : "%.0f", v)
    }
}

struct LeadsWidget: View {
    let leads: LeadsSummary
    let auth: AuthStore
    let onOpen: () -> Void

    var body: some View {
        WidgetShell(title: "Leads", account: leads.accountName, period: leads.period?.label, openTitle: "Open leads", onOpen: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                // Two columns, values on their own line: a number must never wrap under its label.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    kpi("\(leads.total)", "Leads", leads.instagram + leads.facebook > 0 ? "\(leads.instagram) Instagram \u{00b7} \(leads.facebook) Facebook" : nil)
                    kpi("\(leads.phonePercent)%", "With phone", "\(leads.withPhone) of \(leads.total)")
                    kpi("\(leads.creatives)", "Creatives", nil)
                    kpi("\(leads.adsets)", "Ad sets", nil)
                }
                .padding(.horizontal, 14)

                if !leads.topCreatives.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top creatives").font(LiaFont.ui(11.5, .medium)).foregroundStyle(AppConfig.text3)
                            .padding(.horizontal, 14).padding(.bottom, 4)
                        ForEach(leads.topCreatives, id: \.id) { c in
                            HStack(spacing: 10) {
                                Color.clear.frame(width: 26, height: 26)
                                    .background(AppConfig.surface2)
                                    .overlay { if let img = c.image { AuthedImage(url: img, auth: auth) } }
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Text(c.name).font(LiaFont.ui(12.5)).foregroundStyle(AppConfig.ink).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(c.count)").font(LiaFont.ui(12.5, .semibold).monospacedDigit()).foregroundStyle(AppConfig.ink).fixedSize()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func kpi(_ value: String, _ label: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(1)
            Text(value).font(LiaFont.ui(17, .semibold).monospacedDigit()).foregroundStyle(AppConfig.ink).lineLimit(1).minimumScaleFactor(0.7)
            if let sub { Text(sub).font(LiaFont.ui(11).monospacedDigit()).foregroundStyle(AppConfig.text3).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppConfig.surface2.opacity(0.7)))
    }
}

/// The widget's "Open": our small blue capsule, not a full-width bar.
struct WidgetOpenButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                LiaIcon("arrow-up-right", size: 11)
            }
        }
        .buttonStyle(ChatCapsuleButtonStyle())
        .brightness(hover ? 0.04 : 0)
        .onHover { hover = $0 }
        .liaPointer()
    }
}
