import SwiftUI

/// Several pictures in the person's bubble are a fan of cards (like stories), not a column of full
/// tiles. Up to four overlapping cards around a common bottom point (`PhotoFan`), the first picture on top and fully
/// visible, a "+N" badge past four. Hovering opens the fan a little (spring; none with Reduce Motion). Each card is
/// today's `ChatAttachmentTile` drawn at 70%, so a click opens that picture exactly as a single one does and the
/// pictures load the way they always have. One picture never comes here (it stays a single tile).
@MainActor
struct ChatPhotoFan: View {
    let images: [ChatAttachment]
    var auth: AuthStore? = nil
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `ChatAttachmentTile`'s picture (140 x 104, ChatAttach.swift), at 70%.
    private static let tile = CGSize(width: 140, height: 104)
    private static let scale: CGFloat = 0.7
    private var cardW: CGFloat { Self.tile.width * Self.scale }
    private var cardH: CGFloat { Self.tile.height * Self.scale }

    /// The cards' pictures left to right; the last (on top) is the message's first picture.
    private var shown: [ChatAttachment] { Array(images.prefix(PhotoFan.maxCards).reversed()) }

    var body: some View {
        let n = shown.count
        let cards = PhotoFan.cards(count: n, open: open)
        // The box of the open fan, so the bubble never changes size on hover.
        let box = PhotoFan.extent(count: n, cardWidth: Double(cardW), cardHeight: Double(cardH))
        ZStack(alignment: .bottom) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, a in
                card(a, top: i == n - 1)
                    .rotationEffect(.degrees(cards[i].angle), anchor: .bottom)
                    .offset(x: CGFloat(cards[i].x), y: -CGFloat(box.lift))
                    .zIndex(Double(i))
            }
        }
        .frame(width: CGFloat(box.width), height: CGFloat(box.height), alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { h in
            guard !reduceMotion else { open = false; return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { open = h }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(images.count) pictures"))
    }

    private func card(_ a: ChatAttachment, top: Bool) -> some View {
        ChatAttachmentTile(attachment: a, auth: auth)
            .scaleEffect(Self.scale, anchor: .bottom)
            .frame(width: cardW, height: cardH, alignment: .bottom)
            .overlay(alignment: .topTrailing) {
                if top, let more = PhotoFan.more(count: images.count) {
                    Text("+\(more)").font(LiaFont.ui(11, .semibold)).foregroundStyle(Color.white).monospacedDigit()
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(5)
                        .allowsHitTesting(false)
                        .accessibilityLabel(Text("\(more) more pictures"))
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}
