import Foundation

// Billing as the site's settings show it (the server), on the Mac too:
// the App Store price rule is iOS-only and this app ships outside the Store. Checkout and the Stripe
// portal open Stripe's own pages (AppConfig.siteBillingURL, the web app's billing tab, is gone).

struct BillingInvoice: Equatable {
    let date: Double
    let total: Int
    let currency: String
    let status: String
    let url: String?
}

/// api /billing/summary in full: {status, price{amount,currency,interval}, trialEnd, currentPeriodEnd,
/// cancelAtPeriodEnd, card{brand,last4}, invoices[], open_invoice_url}. Amounts are Stripe cents.
struct BillingDetail: Equatable {
    let status: String
    let priceAmount: Int?
    let priceCurrency: String?
    let priceInterval: String?
    let trialEnd: Double?
    let periodEnd: Double?
    let canceling: Bool
    let cardBrand: String?
    let cardLast4: String?
    let invoices: [BillingInvoice]
    let openInvoiceURL: String?

    static let noPlan: Set<String> = ["none", "canceled", "cancelled", "unpaid", "incomplete", "incomplete_expired", "paused"]

    static func parse(_ data: Data) -> BillingDetail? {
        guard let o = JSONRead.object(data), let st = JSONRead.string(o, "status") else { return nil }
        let price = o["price"] as? JSONObject, card = o["card"] as? JSONObject
        return BillingDetail(
            status: st.lowercased(),
            priceAmount: JSONRead.int(price, "amount"), priceCurrency: JSONRead.string(price, "currency"), priceInterval: JSONRead.string(price, "interval"),
            trialEnd: JSONRead.double(o, "trialEnd").flatMap { $0 > 0 ? $0 : nil },
            periodEnd: JSONRead.double(o, "currentPeriodEnd").flatMap { $0 > 0 ? $0 : nil },
            canceling: JSONRead.bool(o, "cancelAtPeriodEnd"),
            cardBrand: JSONRead.string(card, "brand"), cardLast4: JSONRead.string(card, "last4"),
            invoices: JSONRead.objects(o, "invoices").map {
                BillingInvoice(date: JSONRead.double($0, "date") ?? 0, total: JSONRead.int($0, "total") ?? 0,
                               currency: JSONRead.string($0, "currency") ?? "eur", status: JSONRead.string($0, "status") ?? "",
                               url: JSONRead.string($0, "url"))
            },
            openInvoiceURL: JSONRead.string(o, "open_invoice_url").flatMap { $0.isEmpty ? nil : $0 })
    }

    var hasSubscription: Bool { !Self.noPlan.contains(status) }
    var isTrial: Bool { status == "trialing" }
    var isPastDue: Bool { status == "past_due" }

    /// "$20.00 per month" (fmtMoney: cents, en-US). Without a price from Stripe: Lia Pro's, the plan most hold
    /// (PlanCatalog; the old "€15.00 per month" fallback was the retired single plan).
    var priceText: String {
        guard let a = priceAmount else { return PlanCatalog.pro.price + ".00 per month" }
        return Self.money(a, priceCurrency) + " per " + (priceInterval ?? "month")
    }

    /// "$20.00/mo" for the trial line, only when Stripe said what the plan costs.
    private var shortPrice: String? {
        guard let a = priceAmount else { return nil }
        return Self.money(a, priceCurrency) + "/" + ((priceInterval ?? "month") == "year" ? "yr" : "mo")
    }

    static func money(_ cents: Int, _ currency: String?) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = (currency ?? "EUR").uppercased()
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? String(format: "%.2f %@", Double(cents) / 100, (currency ?? "EUR").uppercased())
    }

    /// "Oct 9, 2026" (fmtDate).
    static func date(_ sec: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, yyyy"
        f.timeZone = TimeZone.current
        return f.string(from: Date(timeIntervalSince1970: sec))
    }

    /// The pill and the line under the plan (the server).
    func pill(planTitle: String) -> String {
        if isPastDue { return "Payment issue" }
        if isTrial { return planTitle.isEmpty ? "Free Trial" : planTitle + " \u{00b7} Trial" }
        return planTitle.isEmpty ? "Subscription" : planTitle
    }

    var subLine: String {
        if isPastDue { return "We couldn\u{2019}t process your last payment. Update your card to keep access." }
        if isTrial {
            if canceling {
                return trialEnd.map { "Canceled \u{2014} your free trial ends on \(Self.date($0)) and will not renew. You won\u{2019}t be charged." }
                    ?? "Canceled \u{2014} your free trial will not renew. You won\u{2019}t be charged."
            }
            // No new trials (Free needs no card; Pro $20/mo, Max $100/mo); a subscription still trialing says
            // its own price, never the retired "7-day, then €15/mo".
            let then = shortPrice ?? "your plan"
            return trialEnd.map { "Your free trial ends on \(Self.date($0)), then \(then) begins automatically." }
                ?? "Your free trial is active. \(shortPrice ?? "Your plan") begins when it ends."
        }
        if canceling {
            return periodEnd.map { "Canceled \u{2014} your plan stays active until \(Self.date($0)), then it will not renew." }
                ?? "Canceled \u{2014} your plan will not renew at the end of the current period."
        }
        return periodEnd.map { "Renews automatically on \(Self.date($0))." } ?? "Active subscription."
    }

    /// Which paid plan a past-due subscription held, from what Stripe charges (≈ $100 Max, ≈ $20 Pro).
    func heldPlan(pro: Double = 20, max: Double = 100) -> String? {
        guard let a = priceAmount else { return nil }
        let major = a >= 1000 ? Double(a) / 100 : Double(a)
        if abs(major - max) < 0.51 { return "Lia Max" }
        if abs(major - pro) < 0.51 { return "Lia Pro" }
        return nil
    }
}

/// The three plans and what each says (settings.js PLAN_FEATS). Prices in whole dollars, as Memberstack keeps them;
/// Lia Max is quoted in USD by the product's call.
enum PlanCatalog {
    struct Plan: Equatable { let id: String; let name: String; let tag: String; let price: String; let feats: [String] }
    static let free = Plan(id: "pln_free-example1", name: "Free", tag: "No card required", price: "$0",
                           feats: ["No card required", "Every screen and every tool", "A small Lia allowance, refilled weekly", "No live web access"])
    static let pro = Plan(id: "pln_lia-pro-example2", name: "Lia Pro", tag: "Most popular", price: "$20",
                          feats: ["Much bigger AI budgets than Free", "Lia has web access to study your market", "Everything in Free. Cancel anytime"])
    static let max = Plan(id: "pln_lia-max-example3", name: "Lia Max", tag: "Scale", price: "$100",
                          feats: ["Five times the weekly Lia budget of Pro", "Room for daily work, not just checking in", "Everything in Lia Pro. Cancel anytime"])
}
