import SwiftUI

// Mac 0.2.x: our own dropdown and calendar for the workspace's white surfaces, in place of the
// system Menu / Picker / DatePicker. Both open in DropdownHost's borderless panel under the control (a click outside
// or Esc closes it), drawn white and rounded in LiaFont with WS colours: grey for neutral, WS.blue for the choice.
// Built for the messenger's search first; Settings may reuse them.

/// One row of a LiaDropdown.
struct LiaOption<Value: Hashable> {
    let value: Value
    let title: String
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

/// A capsule that opens a white list. The capsule reads blue while something is chosen.
struct LiaDropdown<Value: Hashable>: View {
    /// The capsule's text while nothing is chosen ("From").
    let title: String
    @Binding var selection: Value?
    /// The first row, which clears the choice ("Anyone"); nil: no such row.
    var noneTitle: String? = nil
    let options: [LiaOption<Value>]
    /// The chosen row's title as the capsule shows it ("Ava" -> "From Ava").
    var label: ((String) -> String)? = nil
    var width: CGFloat = 200
    var align: DropdownAlign = .leading

    var body: some View {
        let chosen = selection.flatMap { s in options.first { $0.value == s }?.title }
        DropdownButton(align: align, highlight: false) {
            LiaChipLabel(text: chosen.map { label?($0) ?? $0 } ?? title, on: chosen != nil)
        } menu: {
            LiaPanel(width: width) { list }
        }
        .fixedSize()
    }

    @ViewBuilder private var list: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            if let noneTitle {
                LiaListRow(title: noneTitle, selected: selection == nil) { selection = nil }
                LiaListDivider()
            }
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                LiaListRow(title: o.title, selected: selection == o.value) { selection = o.value }
            }
        }
        // A long list scrolls inside a fixed height; the panel is sized to its content otherwise.
        if options.count > 9 {
            ScrollView(.vertical, showsIndicators: true) { rows }.frame(height: 300)
        } else {
            rows
        }
    }
}

/// The capsule a dropdown or a filter shows: grey when neutral, blue when set.
struct LiaChipLabel: View {
    let text: String
    let on: Bool
    var chevron = true
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(LiaFont.ui(12, on ? .semibold : .regular)).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(on ? WS.blue : WS.text2)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(on ? WS.blue.opacity(hover ? 0.14 : 0.1) : (hover ? WS.line2 : WS.soft), in: Capsule())
        .contentShape(Capsule())
        .onHover { hover = $0 }
    }
}

/// The white rounded panel every LiaControls popover sits in.
struct LiaPanel<Content: View>: View {
    var width: CGFloat? = nil
    var padding: CGFloat = 5
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WS.surface))   // no shadow
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .padding(DropdownHost.inset)   // the hairline drawn whole
    }
}

/// A list row: the choice in blue with a check; hover a soft grey pill. Choosing closes the panel.
struct LiaListRow: View {
    let title: String
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            DropdownHost.shared.close()
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title).font(LiaFont.ui(13, selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(selected ? WS.blue : WS.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LiaListDivider: View {
    var body: some View { Rectangle().fill(WS.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
}

// MARK: - the calendar

/// A day or a run of days (whole days, `to` nil for one day).
struct LiaDateRange: Equatable {
    var from: Date?
    var to: Date?

    init(from: Date? = nil, to: Date? = nil) { self.from = from; self.to = to }

    var isEmpty: Bool { from == nil }
    var isSingleDay: Bool { from != nil && to == nil }

    /// The first and the last moment covered.
    var bounds: (start: Date, end: Date)? {
        guard let f = from else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: f)
        let last = cal.startOfDay(for: to ?? f)
        let end = (cal.date(byAdding: .day, value: 1, to: last) ?? last).addingTimeInterval(-0.001)
        return (start, end)
    }

    /// "12 Oct" or "12 Oct \u{2013} 15 Oct" (the year when it is not this one).
    var label: String {
        guard let f = from else { return "" }
        let fmt = { (d: Date) -> String in
            let df = DateFormatter()
            let thisYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
            df.setLocalizedDateFormatFromTemplate(thisYear ? "d MMM" : "d MMM yyyy")
            return df.string(from: d)
        }
        guard let t = to else { return fmt(f) }
        return fmt(f) + " \u{2013} " + fmt(t)
    }

    /// A click on a day: starts a new range, or ends the open one (a day before the start moves the start).
    mutating func tap(_ day: Date, allowsRange: Bool = true) {
        let d = Calendar.current.startOfDay(for: day)
        guard allowsRange, let f = from, to == nil else { from = d; to = nil; return }
        if d < f { from = d } else if d > f { to = d }
    }
}

/// A compact month: prev / next, the weekday letters, six weeks of days. A click picks a day; a second click later
/// in time makes it a range, shown as a light blue band between two blue days.
struct LiaCalendar: View {
    @Binding var range: LiaDateRange
    /// Days after this one are greyed out and cannot be picked (nil: no limit).
    var latest: Date? = Date()
    var allowsRange = true
    @State private var month: Date

    init(range: Binding<LiaDateRange>, latest: Date? = Date(), allowsRange: Bool = true) {
        _range = range
        self.latest = latest
        self.allowsRange = allowsRange
        _month = State(initialValue: LiaCalendar.monthStart(range.wrappedValue.from ?? latest ?? Date()))
    }

    private static var cal: Calendar { Calendar.current }

    static func monthStart(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private var canGoNext: Bool {
        guard let latest else { return true }
        return month < Self.monthStart(latest)
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdays
            grid
        }
        .frame(width: 252)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(monthTitle).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
            Spacer()
            LiaCalendarStep(icon: "chevron.left", label: "Previous month", enabled: true) { step(-1) }
            LiaCalendarStep(icon: "chevron.right", label: "Next month", enabled: canGoNext) { step(1) }
        }
        .padding(.leading, 6)
        .padding(.bottom, 2)
    }

    private var monthTitle: String {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return df.string(from: month)
    }

    private func step(_ n: Int) {
        if let m = Self.cal.date(byAdding: .month, value: n, to: month) { month = Self.monthStart(m) }
    }

    private var weekdays: some View {
        let symbols = Self.cal.veryShortStandaloneWeekdaySymbols
        let first = Self.cal.firstWeekday - 1
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(i + first) % 7]).font(LiaFont.ui(10.5, .semibold)).foregroundStyle(WS.text3)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 42 days from the week that holds the 1st.
    private var days: [Date] {
        let cal = Self.cal
        let offset = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -offset, to: month) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var grid: some View {
        let all = days
        return VStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let k = w * 7 + i
                        if k < all.count { cell(all[k]) } else { Color.clear.frame(maxWidth: .infinity, minHeight: 30) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ d: Date) -> some View {
        let cal = Self.cal
        if !cal.isDate(d, equalTo: month, toGranularity: .month) {
            Color.clear.frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        } else {
            let day = cal.startOfDay(for: d)
            let from = range.from.map { cal.startOfDay(for: $0) }
            let to = range.to.map { cal.startOfDay(for: $0) }
            let isStart = from == day
            let isEnd = to == day
            let inside = from.map { day > $0 } == true && to.map { day < $0 } == true
            let disabled = latest.map { day > cal.startOfDay(for: $0) } ?? false
            LiaDayCell(number: cal.component(.day, from: d),
                       picked: isStart || isEnd, today: cal.isDateInToday(d), disabled: disabled,
                       bandLeading: inside || (isEnd && from != nil), bandTrailing: inside || (isStart && to != nil)) {
                range.tap(d, allowsRange: allowsRange)
            }
        }
    }
}

private struct LiaCalendarStep: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(enabled ? WS.text2 : WS.text3.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(hover && enabled ? WS.soft : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text(label))
    }
}

private struct LiaDayCell: View {
    let number: Int
    let picked: Bool
    let today: Bool
    let disabled: Bool
    /// The range's band reaches the cell's leading / trailing half.
    let bandLeading: Bool
    let bandTrailing: Bool
    let action: () -> Void
    @State private var hover = false

    private var ink: Color {
        if picked { return .white }
        if disabled { return WS.text3.opacity(0.5) }
        return today ? WS.blue : WS.ink
    }

    var body: some View {
        Button(action: action) {
            Text(String(number))
                .font(LiaFont.ui(12.5, picked || today ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(picked ? WS.blue : (hover && !disabled ? WS.soft : Color.clear)))
                .frame(maxWidth: .infinity)
                .background(
                    HStack(spacing: 0) {
                        Rectangle().fill(bandLeading ? WS.blue.opacity(0.1) : Color.clear)
                        Rectangle().fill(bandTrailing ? WS.blue.opacity(0.1) : Color.clear)
                    }
                    .frame(height: 30)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .disabled(disabled)
        .onHover { hover = $0 }
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
