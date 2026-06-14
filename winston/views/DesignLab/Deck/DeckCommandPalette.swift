//
//  DeckCommandPalette.swift
//  winston
//
//  Design Lab · Deck — the pull-down community switcher. A translucent glass overlay
//  with a search field; drag up (or tap the scrim) to dismiss.
//

import SwiftUI

struct DeckCommandPalette: View {
  @Binding var selectedSubID: String?
  @Binding var isPresented: Bool
  @State private var query = ""

  private var results: [MockSubreddit] {
    query.isEmpty
      ? MockData.subreddits
      : MockData.subreddits.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.5).ignoresSafeArea()
        .onTapGesture { dismiss() }

      VStack(spacing: 14) {
        Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 6)

        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
          TextField("Jump to a community", text: $query)
            .foregroundStyle(.white)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if !query.isEmpty {
            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
              .foregroundStyle(.white.opacity(0.5))
          }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))

        ScrollView {
          VStack(spacing: 8) {
            paletteRow(title: "Popular", symbol: "flame.fill", tint: DeckPalette.accent,
                       members: nil, selected: selectedSubID == nil) { select(nil) }
            ForEach(results) { sub in
              paletteRow(title: sub.displayName, symbol: nil, tint: sub.accent.color,
                         members: sub.members, selected: selectedSubID == sub.id,
                         monogram: String(sub.name.prefix(1)).uppercased()) { select(sub.id) }
            }
          }
        }
        .frame(maxHeight: 440)
      }
      .padding(16)
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
    }
    .preferredColorScheme(.dark)
    .gesture(
      DragGesture().onEnded { value in
        if value.translation.height < -40 { dismiss() }
      }
    )
  }

  private func select(_ id: String?) {
    selectedSubID = id
    dismiss()
  }

  private func dismiss() {
    withAnimation(.snappy) { isPresented = false }
  }

  @ViewBuilder
  private func paletteRow(
    title: String,
    symbol: String?,
    tint: Color,
    members: Int?,
    selected: Bool,
    monogram: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(tint.opacity(symbol == nil ? 1 : 0.25)).frame(width: 38, height: 38)
          if let symbol {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(DeckPalette.accentInk)
          } else if let monogram {
            Text(monogram).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
          }
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
          if let members {
            Text("\(MockFormatting.compactNumber(members)) members")
              .font(.caption2).foregroundStyle(.white.opacity(0.5))
          }
        }
        Spacer()
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(DeckPalette.accent)
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .background(.white.opacity(selected ? 0.1 : 0.04), in: .rect(cornerRadius: 14))
    }
    .buttonStyle(SpringButtonStyle())
  }
}
