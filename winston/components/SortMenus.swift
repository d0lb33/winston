import SwiftUI

struct PostSortMenu: View {
  @Binding var selection: SubListingSortOption

  private let directSorts: [SubListingSortOption] = [.best, .hot, .new, .rising]

  var body: some View {
    Menu {
      ForEach(directSorts) { option in
        Button {
          selection = option
        } label: {
          SortMenuOptionLabel(icon: option.rawVal.icon, title: option.rawVal.value.capitalized)
        }
      }

      Menu {
        ForEach(SubListingSortOption.TopListingSortOption.allCases, id: \.self) { window in
          Button {
            selection = .top(window)
          } label: {
            SortMenuOptionLabel(icon: window.icon, title: window.rawValue.capitalized)
          }
        }
      } label: {
        SortMenuOptionLabel(icon: SubListingSortOption.top(.all).rawVal.icon, title: "Top")
      }

      Menu {
        ForEach(SubListingSortOption.TopListingSortOption.allCases, id: \.self) { window in
          Button {
            selection = window == .all ? .controversial : .controversialTimed(window)
          } label: {
            SortMenuOptionLabel(icon: window.icon, title: window.rawValue.capitalized)
          }
        }
      } label: {
        SortMenuOptionLabel(icon: SubListingSortOption.controversial.rawVal.icon, title: "Controversial")
      }
    } label: {
      SortMenuIcon(systemName: selection.rawVal.icon, accented: true)
    }
  }
}

struct CommentSortMenu: View {
  @Binding var selection: CommentSortOption
  var isEnabled = true
  var accented = false
  var onSelect: ((CommentSortOption) -> Void)? = nil

  var body: some View {
    Menu {
      if isEnabled {
        ForEach(CommentSortOption.allCases) { option in
          Button {
            selection = option
            onSelect?(option)
          } label: {
            SortMenuOptionLabel(icon: option.rawVal.icon, title: option.rawVal.value.capitalized)
          }
        }
      }
    } label: {
      SortMenuIcon(systemName: selection.rawVal.icon, accented: accented)
        .opacity(isEnabled ? 1 : 0.45)
    }
  }
}

private struct SortMenuIcon: View {
  let systemName: String
  let accented: Bool

  var body: some View {
    Image(systemName: systemName)
      .foregroundColor(accented ? Color.accentColor : nil)
      .fontSize(17, .bold)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
  }
}

private struct SortMenuOptionLabel: View {
  let icon: String
  let title: String

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Image(systemName: icon)
        .foregroundColor(Color.accentColor)
        .fontSize(17, .bold)
    }
  }
}
