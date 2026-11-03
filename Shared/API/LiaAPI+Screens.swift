import Foundation

/// The reads behind the in-chat Creatives, Ad and Leads popups: the same MCP gateway tools creatives.js and
/// leads.js call (api.js call). Read-only by construction: nothing here plans or applies a write.
extension LiaAPI {
    private func scope(_ account: String, _ range: DateRange) -> [String: Any] {
        ["account": account, "from": range.from, "to": range.to]
    }

    /// creatives.js loadInventory: get_ads_tree, flattened to one row per ad.
    func adsTree(account: String, range: DateRange) async throws -> [AdRow] {
        let data = try await mcpCall("get_ads_tree", scope(account, range))
        let o = JSONRead.object(data)
        if o?["tree"] == nil, let e = JSONRead.string(o, "error") { throw AuthError.server(e) }
        return AdsTree.flatten(data)
    }

    /// The account's true spend for the period (compare_periods kpi.spend), the "% of total" denominator.
    func periodSpend(account: String, range: DateRange) async -> Double? {
        var p = scope(account, range)
        p["range"] = "custom"
        guard let d = try? await mcpCall("compare_periods", p) else { return nil }
        return JSONRead.double(JSONRead.object(d)?["kpi"] as? JSONObject, "spend")
    }

    /// get_creatives in batches of 50 (creatives.js chunk(adIds, 50)).
    func creativePreviews(adIds: [String]) async -> [String: CreativePreview] {
        var out: [String: CreativePreview] = [:]
        var i = 0
        while i < adIds.count {
            let batch = Array(adIds[i..<min(i + 50, adIds.count)])
            i += 50
            if let d = try? await mcpCall("get_creatives", ["ad_ids": batch.joined(separator: ",")]) {
                out.merge(CreativePreview.parseMap(d)) { _, n in n }
            }
        }
        return out
    }

    func creativeText(account: String, adId: String) async -> CreativeText? {
        guard let d = try? await mcpCall("get_creative_text", ["account": account, "ad_id": adId]) else { return nil }
        return CreativeText.parse(d)
    }

    func adDemographics(account: String, range: DateRange, adId: String) async throws -> AdDemographics? {
        AdDemographics.parse(try await mcpCall("get_ad_demographics", scope(account, range)), adId: adId)
    }

    func adDaily(account: String, range: DateRange, adId: String) async throws -> AdDaily? {
        var p = scope(account, range)
        p["ad_id"] = adId
        return AdDaily.parse(try await mcpCall("get_daily_breakdown", p), adId: adId)
    }

    func adPlatforms(account: String, range: DateRange, adId: String) async throws -> [SpendBar] {
        AdPlatforms.parse(try await mcpCall("get_platform_breakdown", scope(account, range)), adId: adId)
    }

    /// get_lead_quality takes `account_id`, not `account` (leads.js: the other name counts every account).
    func leadQuality(account: String, range: DateRange) async -> LeadQualitySummary {
        LeadQualitySummary.parse(try? await mcpCall("get_lead_quality", ["account_id": account, "from": range.from, "to": range.to]))
    }

    func leadsPage(account: String, range: DateRange, limit: Int, offset: Int) async throws -> LeadPage {
        var p = scope(account, range)
        p["limit"] = String(limit)
        p["offset"] = String(offset)
        return LeadPage.parse(try await mcpCall("get_leads", p))
    }

    /// creatives.js loadLeads: get_leads for the period, account-wide (no ad filter on the backend).
    func leadsAll(account: String, range: DateRange) async throws -> [LeadRow] {
        LeadRow.parse(LeadPage.parse(try await mcpCall("get_leads", scope(account, range))).rows, duplicatePhones: [])
    }

    func leadOptions(account: String, range: DateRange) async -> LeadOptions {
        let cd = try? await mcpCall("get_campaigns", scope(account, range))
        let sd = try? await mcpCall("get_adsets", scope(account, range))
        return LeadOptions(campaigns: LeadOptions.parseCampaigns(cd), adsets: LeadOptions.parseAdsets(sd))
    }

    /// Every campaign, ad set and ad of the account by name (find_entity with no query: the skeleton from the
    /// tree cache, no date window). One read per account per ten minutes at most (OmniEntityCache).
    func accountEntities(account: String) async throws -> [OmniEntity] {
        let data = try await mcpCall("find_entity", ["account": account])
        guard let e = OmniEntities.parse(data) else {
            throw AuthError.server(JSONRead.string(JSONRead.object(data), "error") ?? "find_entity")
        }
        return e
    }

    /// A creative's video to a temporary file for AVPlayer. Our own /meta/video sits behind the session gate,
    /// so the bytes come with the session header (AVPlayer cannot send one); Meta's CDN gets none.
    func videoFile(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 180)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        if LiaAPI.isOurs(url) {
            guard let token = try? await token() else { return nil }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (tmp, resp) = try? await session.download(for: req) else { return nil }
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400 else {
            try? FileManager.default.removeItem(at: tmp)   // an error page, not a video: not left in tmp
            return nil
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("lia-video-" + UUID().uuidString + ".mp4")
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return nil }
        return dest
    }
}
