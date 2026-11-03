import Foundation

/// Stripe Checkout and the Stripe customer portal, as the site opens them through Memberstack's DOM SDK
/// (settings.js startCheckout / openPortal -> @memberstack/dom purchasePlansWithCheckout /
/// launchStripeCustomerPortal). The SDK posts to Memberstack's client API and redirects to the URL that
/// comes back; the app makes the same POST and opens that URL in the system browser.
enum StripeCheckout {
    /// settings.js: successUrl location.origin + '/overview', cancelUrl location.origin + '/settings/billing'.
    static let successURL = "https://liaisone.com/overview"
    static let cancelURL = "https://liaisone.com/settings/billing"
    /// The SDK sends window.location.href as origin_url; on the site that is the billing tab.
    static let originURL = "https://liaisone.com/settings/billing"

    /// Checkout or the portal in our pop-up window over Settings: Stripe sending the window back to our
    /// site (success, cancel, the portal's way back) is the end of it. The window closes there and never loads our page.
    static func isReturn(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let h = url.host?.lowercased() else { return false }
        return h == "liaisone.com" || h == "www.liaisone.com"
    }

    static let checkoutPath = "/member/plans/create-checkout-session"
    static let portalPath = "/member/create-billing-portal-session"
    /// getPlans: GET /app, plans under data.plans.
    static let plansPath = "/app"

    /// The checkout body, or nil for anything that is not a Memberstack price (settings.js: no price, no checkout).
    static func checkoutBody(priceId: String) -> [String: Any]? {
        guard priceId.hasPrefix("prc_") else { return nil }
        return ["priceId": priceId, "success_url": successURL, "cancel_url": cancelURL, "origin_url": originURL]
    }

    /// launchStripeCustomerPortal is called with no params on the site: no return_url, only origin_url.
    static func portalBody() -> [String: Any] { ["origin_url": originURL] }

    /// settings.js planPrice: the plan's first price id from getPlans.
    static func priceId(plans data: Data, planId: String) -> String? {
        guard let o = JSONRead.object(data) else { return nil }
        let inner = o["data"] as? JSONObject
        let plans = (inner?["plans"] as? [JSONObject]) ?? (o["plans"] as? [JSONObject]) ?? []
        guard let plan = plans.first(where: { JSONRead.string($0, "id") == planId }),
              let price = (plan["prices"] as? [JSONObject])?.first,
              let id = JSONRead.string(price, "id"), !id.isEmpty else { return nil }
        return id
    }

    enum Reply: Equatable { case url(URL), error(String) }

    /// The SDK reads request.data.url; an error comes back as {error: {message, code}}.
    static func reply(_ data: Data) -> Reply {
        let o = JSONRead.object(data)
        if let e = o?["error"] as? JSONObject {
            return .error(JSONRead.string(e, "message") ?? JSONRead.string(e, "code") ?? "")
        }
        if let e = JSONRead.string(o, "error"), !e.isEmpty { return .error(e) }
        let inner = o?["data"] as? JSONObject
        if let s = JSONRead.string(inner, "url") ?? JSONRead.string(o, "url"),
           let u = URL(string: s), u.scheme == "https" { return .url(u) }
        return .error("")
    }

    /// What "Fix payment" on the billing prompt reopens: the plan by its name (shell.js bxRender plan_name).
    static func planId(named name: String) -> String? {
        let n = name.replacingOccurrences(of: " \u{00b7} Trial", with: "").trimmingCharacters(in: .whitespaces)
        return [PlanCatalog.pro, PlanCatalog.max].first { $0.name == n }?.id
    }
}
