# Posts Navigation Simplification Plan

## Goal

Make Posts navigation reliable across iPhone, foldable closed/open states, iPad,
Stage Manager, Split View, rotation, and resizable windows by separating:

- The browsing state the user cares about.
- The layout shell used to present that state.

The app should not decide behavior from device family (`iPhone` vs `iPad`). It
should decide from the actual available width.

## Product Decision

Use one shared Posts browsing model and render it in two different ways:

- Compact width: one `NavigationStack`. The feed is the root. Home, Popular,
  Saved, subreddits, and saved lists are feed scopes selected from a menu, sheet,
  or picker.
- Wide width: one `NavigationSplitView`. The left column shows feed scopes, the
  middle column shows the selected feed, and the right column shows the selected
  post.

This keeps the foldable advantage on wide screens: quick subreddit switching at
a glance. It also avoids making compact iPhone behavior depend on
`NavigationSplitView`'s collapsed-column choreography.

## Why Change

The current Posts implementation uses `NavigationSplitView` for both regular
and compact behavior. On compact widths, the subreddit sidebar becomes part of
the collapsed stack, so the app has to manage which column is currently visible
with `preferredCompactColumn`, tab reselect actions, active-column tracking, and
special "reveal subreddit selector" behavior.

That makes the compact phone path fragile. The user-facing mental model on a
phone is simpler:

1. The feed is home.
2. A subreddit/home/popular choice changes the feed source.
3. A post opens from the feed.
4. Back from a post returns to the feed.

The subreddit list should not be a required previous screen in the compact stack.

## Target State Model

Create one source of truth for Posts browsing state.

```swift
enum FeedScope: Hashable, Codable {
  case home
  case popular
  case saved
  case subreddit(id: String)
  case savedList(id: UUID)
  case savedListsOverview
}

@Observable
@MainActor
final class PostsNav {
  var scope: FeedScope = .popular

  // Feed state
  var selectedPostID: String?
  var feedScrollPositionID: String?
  var contentPath: [NavDest] = []

  // Detail state
  var detailPost: Post?
  var detailHighlightID: String?
  var detailPath: [NavDest] = []

  // Surface commands
  var contentScrollToTopRequest = 0
  var detailScrollToTopRequest = 0
}
```

`scope` replaces the current stringly `community` selection. Home, Popular,
Saved, subreddits, and saved lists are all the same kind of thing: a feed source.

`selectedPostID` / `detailPost` describes whether a post is open. The compact
and wide shells both derive their UI from that state.

`feedScrollPositionID` preserves the row nearest the top of the feed. Do not try
to preserve exact pixel offset across different shells; restoring by row identity
is more realistic and stable.

Compact stack state should be a projection of this model, not a second source of
truth. A compact path setter can decompose system back gestures into state
changes: nested detail pops update `detailPath`; popping the post clears
`selectedPostID` / `detailPost`; returning to the feed leaves `scope` intact.

## Layout Selection

Use available width, not idiom.

```swift
let isWide = availableWidth >= PostsLayout.expandedMinWidth
```

Initial threshold can stay close to the current value:

```swift
enum PostsLayout {
  static let expandedMinWidth: CGFloat = 820
}
```

Rules:

- Never branch on `UIDevice.current.userInterfaceIdiom`.
- Treat `horizontalSizeClass` as advisory, not authoritative.
- A foldable that reports as phone still gets the wide shell when the unfolded
  window is wide enough.
- A narrow iPad or Stage Manager window still gets the compact shell.

## Compact Rendering

Compact Posts should be a normal stack with the feed as root.

```swift
NavigationStack(path: nav.compactPathBinding) {
  PostsFeedScreen(
    scope: nav.scope,
    selectedPostID: $nav.selectedPostID,
    scrollPositionID: $nav.feedScrollPositionID
  )
  .toolbar {
    FeedScopePickerButton(scope: $nav.scope)
  }
  .navigationDestination(for: NavDest.self) { destination in
    destinationView(destination)
  }
}
```

Preferred behavior:

- App opens to the feed, not the subreddit list.
- The toolbar title/menu shows the active scope.
- Tapping the scope control opens a scope picker.
- Tapping a post pushes post detail.
- Back from post returns to the feed.
- Back from nested detail destinations pops those destinations first.

The compact shell should not use the subreddit sidebar as a collapsed
`NavigationSplitView` column.

## Wide Rendering

Wide Posts should keep the native three-column split.

```swift
NavigationSplitView {
  FeedScopeSidebar(selection: $nav.scope)
} content: {
  PostsFeedScreen(
    scope: nav.scope,
    selectedPostID: $nav.selectedPostID,
    scrollPositionID: $nav.feedScrollPositionID
  )
} detail: {
  PostDetailColumn(
    post: nav.selectedPost,
    path: $nav.detailPath
  )
}
```

Preferred behavior:

- Sidebar shows Home, Popular, Saved, saved lists, and subreddits.
- Feed column updates when `scope` changes.
- Selecting a post highlights the feed row and shows the post in detail.
- Detail pushes, like user profile or crosspost, stay in the detail column.
- The sidebar remains visible when width allows because it is useful on
  foldables and iPad.

## Fold / Unfold Behavior

Both shells must render the same `PostsNav` instance.

Compact to wide:

```text
compact:
Feed(scope: r/swift) -> Post(123)

wide:
[Scopes] [Feed: r/swift, row 123 selected] [Post 123]
```

Wide to compact:

```text
wide:
[Scopes] [Feed: r/swift] [Post 123]

compact:
Feed(scope: r/swift) -> Post(123)
```

Expected preserved state:

- Active feed scope.
- Loaded feed model where possible.
- Selected/open post.
- Detail navigation path.
- Feed scroll restored near `feedScrollPositionID`.
- Feed row selection on wide layouts.

Expected non-goal:

- Exact pixel scroll offset across a shell swap.

## Migration Steps

1. Introduce `FeedScope`.
   - Replace `PostsNav.community: String?` with `PostsNav.scope: FeedScope`.
   - Add conversion helpers for existing launch-feed defaults, saved-list route
     ids, subreddit ids, and Reddit pseudo-feeds.

2. Extract a shared feed surface.
   - Make the current feed rendering accept `FeedScope`.
   - Keep `AuroraFeedModel` ownership above both compact and wide shells.
   - Preserve `feedScrollPositionID` binding.

3. Build `CompactPostsShell`.
   - Feed is the stack root.
   - Scope picker is a toolbar/menu/sheet.
   - Post detail is pushed from shared selected-post state.
   - Remove compact reliance on `preferredCompactColumn`.

4. Build `WidePostsSplitShell`.
   - Keep `NavigationSplitView` for wide layouts.
   - Sidebar is only a wide presentation of `FeedScope` selection.
   - Feed and detail columns bind to the same `PostsNav`.

5. Replace `AuroraRoot` shell switch.
   - Measure available width once.
   - Render compact or wide shell from the same `PostsNav`.
   - Avoid wrapping `NavigationSplitView` in layout containers that break native
     split behavior.

6. Simplify tab reselect behavior.
   - Compact single tap: scroll feed/detail to top, then pop one layer, then
     remain at feed root.
   - Compact double tap: reset to launch feed/root if desired.
   - Wide reselect: scroll visible content first, then reset only when already at
     root.
   - Remove "reveal subreddit selector" as a compact navigation operation.

7. Delete obsolete split choreography.
   - Remove Posts-only uses of `preferredCompactColumn` once compact no longer
     depends on collapsed split columns.
   - Remove active-column tracking that only exists to infer collapsed split
     state.
   - Keep `NavigationSplitView` state only where the wide shell actually needs it.

8. Update deep-link routing.
   - Deep link to subreddit/feed sets `scope`.
   - Deep link to post sets `scope` when known, sets selected/detail post, and
     opens compact or wide presentation based on current width.
   - Legacy `Nav.to(...)` bridge should translate into `PostsNav` state, not into
     split-column commands.

## Verification Matrix

Compact phone / folded:

- Launch app: feed is root.
- Change Home/Popular/subreddit from picker.
- Open post, push user profile from post, back returns profile -> post -> feed.
- Tab reselect does not jump to a hidden subreddit-list screen.
- Scroll feed, open post, back returns to roughly same feed row.

Wide / unfolded:

- Sidebar, feed, and detail are visible when width permits.
- Selecting a subreddit updates feed without destroying open layout.
- Selecting a post shows detail and highlights row.
- Detail path pushes stay in right column.
- Scope list remains quickly accessible.

Fold / unfold:

- Feed scrolled in compact, unfold: feed remains on same scope and near same row.
- Post open in compact, unfold: post appears in right column, feed appears in
  middle column.
- Post open in wide, fold: compact stack shows feed -> post.
- Nested detail open in wide, fold: compact preserves nested detail path.
- Fold/unfold repeatedly without losing selected post or breaking back.

Window edge cases:

- Narrow iPad Split View uses compact shell.
- Wide Stage Manager window uses wide shell.
- Foldable reported as phone uses wide shell when unfolded width passes threshold.
- Rotation does not reset `scope`, selected post, or feed position.

## Risks

- Swapping between two shells can recreate view identity. State that must survive
  must live in `PostsNav` or another shared model above the shell switch.
- Exact scroll offset is unlikely to survive reliably; row-id restoration should
  be treated as the supported behavior.
- If `Post` cannot be reliably resolved from `selectedPostID` after a feed model
  reload, `detailPost` must retain enough data to keep detail visible.
- SwiftUI may animate shell swaps awkwardly. Prefer correctness first; tune
  animation after navigation is stable.

## Done Criteria

- Compact Posts no longer uses the subreddit sidebar as a collapsed navigation
  column.
- Wide Posts still uses `NavigationSplitView`.
- Device idiom checks are not used for Posts layout selection.
- Fold/unfold preserves scope, selected post, detail path, and approximate feed
  position.
- The tab reselect path no longer depends on inferred collapsed split columns.
- The old compact `preferredCompactColumn` bug class is removed, not patched.
