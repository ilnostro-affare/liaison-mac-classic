import Foundation

// Quick actions (ai.js SLASH_CMDS, wireSlashPalette): "/" in the box or [+] > Quick actions turns a command into a
// sentence with chips above the input; a chip picks an ad set / campaign or takes a name or a number. What is sent is
// "[quick_action] " + the sentence, then whatever was typed under it.

struct SlashPart: Equatable {
    enum Kind: String { case text, adset, campaignOrAdset = "campaign_or_adset", plainText = "text_chip", num }
    let kind: Kind
    let text: String          // the fixed words, or the chip's label
    var placeholder: String? = nil
    var value: String? = nil  // a chip's starting value

    static func t(_ s: String) -> SlashPart { SlashPart(kind: .text, text: s) }
    var isChip: Bool { kind != .text }
    /// Entity chips must be filled before sending; text and numbers carry a default or may stay empty.
    var required: Bool { kind == .adset || kind == .campaignOrAdset }
    var plain: Bool { kind == .plainText || kind == .num }
}

struct SlashCommand: Equatable, Identifiable {
    let cmd: String
    let desc: String
    let parts: [SlashPart]
    var id: String { cmd }

    static let all: [SlashCommand] = [
        SlashCommand(cmd: "/adset", desc: "New ad set from a template", parts: [
            .t("New ad set from template "), SlashPart(kind: .adset, text: "pick ad set"),
            .t(", name it "), SlashPart(kind: .plainText, text: "name", placeholder: "new ad set name"),
            .t(", budget "), SlashPart(kind: .num, text: "10", value: "10"), .t(" \u{20ac}/day")]),
        SlashCommand(cmd: "/ad", desc: "New ad from your media", parts: [
            .t("New ad from my media into ad set "), SlashPart(kind: .adset, text: "pick ad set"),
            .t(", texts "), SlashPart(kind: .plainText, text: "inherit", placeholder: "primary text, or leave as inherit", value: "inherit from the reference ad")]),
        SlashCommand(cmd: "/rule", desc: "Protective pause rule", parts: [
            .t("Protective rule: pause "), SlashPart(kind: .campaignOrAdset, text: "pick scope"),
            .t(" if CPL exceeds "), SlashPart(kind: .num, text: "15", value: "15"), .t(" \u{20ac} over "),
            SlashPart(kind: .num, text: "3", value: "3"), .t(" days")]),
        SlashCommand(cmd: "/duplicate", desc: "Duplicate a campaign or ad set", parts: [
            .t("Duplicate "), SlashPart(kind: .campaignOrAdset, text: "pick entity"),
            .t(", rename everything inside with suffix "), SlashPart(kind: .plainText, text: " v2", placeholder: "suffix", value: " v2")]),
        SlashCommand(cmd: "/budget", desc: "Change a budget", parts: [
            .t("Set the daily budget of "), SlashPart(kind: .campaignOrAdset, text: "pick entity"),
            .t(" to "), SlashPart(kind: .num, text: "10", value: "10"), .t(" \u{20ac}")]),
        SlashCommand(cmd: "/activate", desc: "Turn an entity on", parts: [
            .t("Activate "), SlashPart(kind: .campaignOrAdset, text: "pick entity")]),
    ]

    /// The palette's rows for what follows the slash (ai.js draw).
    static func matching(_ q: String) -> [SlashCommand] {
        let q = q.lowercased()
        return all.filter { q.isEmpty || $0.cmd.dropFirst().hasPrefix(q) || $0.desc.lowercased().contains(q) }
    }

    /// ai.js slashCtx: a slash at the start or after a space, with no space typed after it yet.
    static func context(_ text: String, caret: Int? = nil) -> (at: Int, before: String, query: String)? {
        let chars = Array(text)
        let pos = min(caret ?? chars.count, chars.count)
        guard pos > 0, let i = chars[0..<pos].lastIndex(of: "/") else { return nil }
        let before = String(chars[0..<i])
        if let last = before.last, !last.isWhitespace { return nil }
        let frag = String(chars[(i + 1)..<pos])
        if frag.contains(where: \.isWhitespace) { return nil }
        return (i, before.trimmingCharacters(in: .whitespacesAndNewlines), frag.lowercased())
    }
}

/// One entity from /call/entity_options.
struct SlashEntity: Equatable, Identifiable {
    let id: String
    let name: String
    let kind: String              // "campaign" | "ad set"
    let campaign: String?
    let accountName: String?
    let active: Bool
    let campaignCBO: Bool
    let campaignDailyBudget: String?
    let campaignCurrency: String?

    /// {ok, campaigns[], adsets[], accounts[]}. Campaigns first when both are wanted, as the site lists them.
    static func parse(_ data: Data) -> (entities: [SlashEntity], accounts: Int)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        func rows(_ key: String, _ kind: String) -> [SlashEntity] {
            JSONRead.objects(o, key).compactMap { r in
                guard let n = JSONRead.string(r, "name") else { return nil }
                return SlashEntity(id: JSONRead.string(r, "id") ?? "", name: n, kind: kind, campaign: JSONRead.string(r, "campaign"),
                                   accountName: JSONRead.string(r, "account_name"), active: JSONRead.bool(r, "active"),
                                   campaignCBO: JSONRead.bool(r, "campaign_cbo"),
                                   campaignDailyBudget: JSONRead.string(r, "campaign_daily_budget"),
                                   campaignCurrency: JSONRead.string(r, "campaign_currency"))
            }
        }
        return (rows("campaigns", "campaign") + rows("adsets", "ad set"), JSONRead.objects(o, "accounts").count)
    }
}

/// The sentence being filled (ai.js buildBar / barText / barComplete).
struct QuickBar: Equatable {
    struct Chip: Equatable {
        var value: String
        var campaign = ""
        var account = ""
        var entityId = ""
        /// An ad set under a CBO campaign: the budget chip says where the budget is and stops being editable.
        var locked = false
    }
    let command: SlashCommand
    var chips: [Int: Chip] = [:]   // index into command.parts

    init(_ c: SlashCommand) {
        command = c
        for (i, p) in c.parts.enumerated() where p.isChip { chips[i] = Chip(value: p.value ?? "") }
    }

    var complete: Bool { command.parts.indices.allSatisfy { !command.parts[$0].required || !(chips[$0]?.value.isEmpty ?? true) } }
    var firstOpen: Int? { command.parts.indices.first { command.parts[$0].required && (chips[$0]?.value.isEmpty ?? true) } }

    /// What goes after "[quick_action] ": entities in «», with their id, campaign and account; plain chips as typed.
    var text: String {
        var out = ""
        for (i, p) in command.parts.enumerated() {
            if !p.isChip { out += p.text; continue }
            guard let c = chips[i], !c.value.isEmpty else { continue }
            if p.plain || c.locked { out += c.value; continue }
            out += "\u{00ab}" + c.value + "\u{00bb}"
            if !c.entityId.isEmpty { out += " (id " + c.entityId + ")" }
            if !c.campaign.isEmpty { out += " in campaign \u{00ab}" + c.campaign + "\u{00bb}" }
            if !c.account.isEmpty { out += " (account \u{00ab}" + c.account + "\u{00bb})" }
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if chips.values.contains(where: \.locked) {
            if out.hasSuffix(") \u{20ac}/day") { out = String(out.dropLast(" \u{20ac}/day".count)) }
            else if out.hasSuffix(" \u{20ac}/day") { out = String(out.dropLast(" \u{20ac}/day".count)) }
        }
        return out
    }

    /// Picking an entity for an ad set chip: under a CBO campaign the budget chip locks (ai.js entityPicker).
    mutating func pick(_ e: SlashEntity, at i: Int, manyAccounts: Bool) {
        chips[i] = Chip(value: e.name, campaign: e.kind == "ad set" ? (e.campaign ?? "") : "",
                        account: manyAccounts ? (e.accountName ?? "") : "", entityId: e.id)
        guard command.parts[i].kind == .adset,
              let b = command.parts.indices.first(where: { command.parts[$0].kind == .num && (command.parts.indices.contains($0 + 1) && command.parts[$0 + 1].text.contains("\u{20ac}/day")) }) else { return }
        if e.campaignCBO {
            let per = e.campaignDailyBudget.map { ", " + $0 + " " + (e.campaignCurrency ?? "") + "/day" } ?? ""
            chips[b] = Chip(value: "on the campaign (CBO" + per + ")", locked: true)
        } else if chips[b]?.locked == true {
            chips[b] = Chip(value: command.parts[b].value ?? command.parts[b].text)
        }
    }

    /// The label a chip shows: its value cut at 26, or its placeholder word.
    func label(_ i: Int) -> String {
        let p = command.parts[i]
        guard let c = chips[i], !c.value.isEmpty else { return p.text }
        if c.locked, let cbo = c.value.range(of: "(CBO") {
            let inner = c.value[cbo.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ", )"))
            return "CBO " + (inner.isEmpty ? "campaign budget" : inner)
        }
        return c.value.count > 26 ? String(c.value.prefix(25)) + "\u{2026}" : c.value
    }
}
