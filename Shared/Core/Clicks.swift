import Foundation

// 0.2.11: "buttons are hard to press - the agents, 'Open creative' in the
// messenger; the pointer is sometimes an arrow, sometimes a finger. Everything must work on the first click, within
// 400 ms, 100 ms where we can." The pure rules behind the app's clicks (the views are in App/Shell/Clickable.swift).
enum LiaClicks {
    /// A press becomes a drag only past this distance (points). Below it the press stays a click: a hand moving 1-3 pt
    /// while clicking used to start the drag (the canvas pan at 2 pt) and the click under it never fired.
    static let dragStart: CGFloat = 4

    static func isDrag(dx: CGFloat, dy: CGFloat) -> Bool {
        (dx * dx + dy * dy).squareRoot() >= dragStart
    }

    enum Kind: Equatable { case single, double }

    /// What one click is, from AppKit's click count. A view that also has a double-click action fires its single
    /// action at once on the first click and the double one on the second, instead of SwiftUI's
    /// `onTapGesture(count: 2)` + `onTapGesture`, which holds every single click back for the double-click interval
    /// (300-500 ms) to see whether a second one comes.
    static func kind(clickCount: Int) -> Kind { clickCount >= 2 ? .double : .single }

    /// The dock's eyes follow the pointer: a move smaller than this (points) does not redraw the dock. Each redraw
    /// re-laid out every agent; under a still-moving hand that kept the main thread busy right when the click came.
    static let pointerStep: CGFloat = 2

    static func pointerMoved(from old: CGPoint?, to new: CGPoint?, step: CGFloat = pointerStep) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (a?, b?): return abs(a.x - b.x) >= step || abs(a.y - b.y) >= step
        }
    }

    /// A chip in an answer's text (an entity, a link, "Open creative"): a press on it acts unless it is the second
    /// press of a double click on the same chip (that one already acted). A double click that starts on the text
    /// next to a chip and ends on the chip still opens it; before, any press with clickCount 2 was dropped, so a
    /// quick second try after a click elsewhere did nothing.
    static func chipFires(clickCount: Int, chip: Int, lastFired: Int?) -> Bool {
        clickCount <= 1 || lastFired != chip
    }
}

/// The account and period a creatives / ad / leads popup opens on from a widget in a conversation: the account the
/// widget carried (digits only, "act_" dropped), else the conversation's own, else the first connected one; the
/// name the widget carried for its own account, else the best known one, else the id.
enum PopupAccountRule {
    static func resolve(given: String?, givenName: String?, thread: [(id: String, name: String)],
                        known: [(id: String, name: String)]) -> (id: String, name: String) {
        let digits = (given ?? "").filter { $0.isASCII && $0.isNumber }
        let id = !digits.isEmpty ? digits : (thread.first?.id ?? known.first?.id ?? "")
        let bare = id.filter { $0.isASCII && $0.isNumber }
        func same(_ x: String) -> Bool { !bare.isEmpty && x.filter { $0.isASCII && $0.isNumber } == bare }
        var name = id
        if let n = thread.first(where: { same($0.id) })?.name, !n.isEmpty { name = n }
        if let n = known.first(where: { same($0.id) })?.name, !n.isEmpty { name = n }
        if !digits.isEmpty, let n = givenName, !n.isEmpty { name = n }
        return (id, name)
    }

    /// (rule 11: a result says which account it is for): one ad by id opens only on an account that is known
    /// to hold it: the one the block carried, else the conversation's when it has exactly one. Never "the first
    /// connected account" (an ad id under another account opens an empty or wrong popup). nil: refuse and say so.
    static func strict(given: String?, givenName: String?, thread: [(id: String, name: String)],
                       known: [(id: String, name: String)]) -> (id: String, name: String)? {
        let digits = (given ?? "").filter { $0.isASCII && $0.isNumber }
        if digits.isEmpty && thread.count != 1 { return nil }
        let r = resolve(given: given, givenName: givenName, thread: thread, known: known)
        return r.id.isEmpty ? nil : r
    }

    static let unknownAccount = "This ad does not say which ad account it belongs to. Open it from Creatives instead."
}
