import SwiftUI

/// shell.js cxRender: the first-run dialog over the window when Meta is not connected, or the connection expired.
struct MetaNudgeView: View {
    @EnvironmentObject private var app: AppModel
    let expired: Bool
    let onLater: () -> Void
    let onConnect: () -> Void
    /// shell.js bxRender reuses the same dialog: set for the billing prompt.
    var billing: AppModel.BillingNudge? = nil

    var body: some View {
        ZStack {
            Color(red: 8 / 255, green: 10 / 255, blue: 18 / 255).opacity(0.55).ignoresSafeArea().onTapGesture(perform: onLater)
            VStack(alignment: .leading, spacing: 0) {
                Text(expired || billing != nil ? "Action needed" : "Setup").font(LiaFont.ui(11, .bold)).tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(expired || billing != nil ? Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255) : AppConfig.text3)
                    .padding(.bottom, 8)
                Text(billing.map { $0.pastDue ? "Your payment did not go through" : "Your plan is no longer active" }
                     ?? (expired ? "Your Meta connection expired" : "Connect Meta to see your data"))
                    .font(LiaFont.ui(17, .semibold)).tracking(-0.17).padding(.bottom, 8)
                Text(billing.map { $0.plan + " is on hold, so the account is running on Free limits for now. Everything you have built stays exactly where it is: campaigns, rules, Relay and your chat history are untouched." } ?? (expired
                     ? "Meta access runs out about every 60 days. Your numbers are frozen at the last sync and new leads are not arriving. Reconnecting takes one click and keeps all your history."
                     : "Liaison works on top of your Meta ad account. Until it is connected, the assistant can talk to you but it cannot see a single campaign, creative or lead."))
                    .font(LiaFont.ui(13.5)).foregroundStyle(AppConfig.text2).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)
                if !expired && billing == nil {
                    VStack(alignment: .leading, spacing: 0) {
                        row("Performance", " for every campaign, ad set and ad")
                        row("Leads in real time", ", matched to the ad that produced them")
                        row("Edits you confirm", ", prepared by the assistant and applied by you")
                    }
                    .overlay(alignment: .top) { Rectangle().fill(AppConfig.line2).frame(height: 1) }
                    .padding(.bottom, 20)
                }
                HStack(spacing: 9) {
                    Spacer()
                    Button(action: onLater) {
                        Text(expired && billing == nil ? "Later" : "Not now").font(LiaFont.ui(13.5, .medium)).opacity(0.72)
                            .padding(.horizontal, 17).padding(.vertical, 9)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppConfig.line3))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.liaPlain).liaHover(.fill, radius: 9).keyboardShortcut(.cancelAction)
                    Button(action: primary) {
                        Text(billing != nil ? "Fix payment" : (expired ? "Reconnect Meta" : "Connect Meta")).font(LiaFont.ui(13.5, .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 17).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(AppConfig.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.liaPlain).liaHover(.solid).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20)
            .frame(maxWidth: 412)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppConfig.ddBg).shadow(color: .black.opacity(0.46), radius: 24, y: 18))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppConfig.line2))
            .padding(16)
        }
    }

    /// "Fix payment" opens Stripe itself (AppModel.fixPayment); the Meta prompt keeps its own action.
    private func primary() {
        if let b = billing { app.fixPayment(b) } else { onConnect() }
    }

    private func row(_ b: String, _ rest: String) -> some View {
        (Text(b).foregroundColor(AppConfig.ink).fontWeight(.medium) + Text(rest))
            .font(LiaFont.ui(13)).foregroundStyle(AppConfig.text2)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(AppConfig.line2).frame(height: 1) }
    }
}
