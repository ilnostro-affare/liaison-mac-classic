import AppKit

/// Upgrade goes straight to Stripe: the same Memberstack calls the site's Billing tab makes,
/// the Stripe URL opened in the system browser. A failure is the site's modal, as an alert with the same title.
@MainActor
enum StripeOpen {
    /// settings.js startCheckout: Checkout for one plan (Free to Pro or Max, or switching while on hold).
    static func checkout(planId: String, auth: AuthStore) async {
        do { open(try await LiaAPI(auth: auth).checkoutURL(planId: planId), auth: auth) }
        catch { alert("Could not open checkout", userMessage(for: error)) }
    }

    /// settings.js openPortal: cancel, resume, update the card, Pro to Max.
    static func portal(auth: AuthStore) async {
        do { open(try await LiaAPI(auth: auth).portalURL(), auth: auth) }
        catch { alert("Could not open the billing portal", "Please try again in a moment.") }
    }

    /// The limit strip under the input: Free gets Lia Pro's checkout; a paid plan below Max moves up in the
    /// portal, as settings.js does for Pro to Max (one subscription, prorated, never a second checkout).
    static func upgrade(tier: String?, auth: AuthStore) async {
        if tier == "free" || tier == nil || tier == "" { await checkout(planId: PlanCatalog.pro.id, auth: auth) }
        else { await portal(auth: auth) }
    }

    /// Billing's pop-up closed (paid, cancelled, the portal left): the Billing tab reads its state again.
    static let returned = Notification.Name("lia.billing.returned")

    /// A Stripe page (checkout, portal, an invoice). With Settings open (Stripe opened UNDER Settings):
    /// in our pop-up window above it, closing when Stripe sends it back to our site. Otherwise the system browser,
    /// As.
    static func open(_ url: URL, auth: AuthStore) {
        guard SettingsWindow.shared.isOpen else { ExternalLink.openInSystemBrowser(url); return }
        PopupBrowser.open(url, auth: auth, title: "Billing", isReturn: StripeCheckout.isReturn) {
            NotificationCenter.default.post(name: returned, object: nil)
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
