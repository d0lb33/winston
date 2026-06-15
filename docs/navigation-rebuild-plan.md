# Navigation Rebuild — Native Adaptive Plan

Branch: `list-support`. Goal: make navigation correct and robust on foldables, Stage
Manager, iPad Split View, rotation, and resizable windows by moving to a native,
selection-driven `NavigationSplitView` + `.sidebarAdaptable` `TabView` model, and
deleting the hand-rolled choreography that fights the framework.

Decisions (locked with the user 2026-06-15):
- **Full native rebuild** (not harden-in-place).
- **Adopt `.tabViewStyle(.sidebarAdaptable)`** — tab bar auto-becomes a sidebar at
  regular widths. Custom `TabBarOverlay` glass is dropped/relocated.
- **Drop the custom gestures** — remove the private-API full-swipe-back and the
  hand-rolled forward-swipe. Rely on the system interactive back, which works in
  both compact and regular and survives resize.

## Root cause (why it breaks today)

Navigation state lives in **two parallel sources of truth that must be manually
reconciled**, and they desync exactly at resize/fold/size-class boundaries:

- `Router.fullPath: [NavDest]` — legacy 2023 flat stack (`Navigation/Router.swift:61`),
  drives the detail `NavigationStack`.
- `RedditSplitNavigationModel` — a *second* model holding `contentPath`, `detailPost`,
  `selectedPostID`, `columnVisibility`, `preferredColumn`, and a `forwardRoutes`
  history (`Navigation/RedditSplitNavigation.swift:66`).

`NavigationSplitView` already collapses its columns into one stack when compact and
splits them back out when regular — automatically. The app re-implements that by hand
(`columnVisibility`/`preferredColumn` + `absorbRootNavigationPathIfNeeded`,
`recordRouterPathChange`, `recordPreferredColumnChange`, `suppressNextRouterPopRecord`,
`restoreNextForwardRoute`). Every one of those methods is a patch over storing state the
framework already owns. That's the "I resized and my open post vanished / duplicated /
back button died" class of bug.

Compounding hacks:
- **Private API** for full-swipe-back: `interactivePopGestureRecognizer.value(forKey:
  "targets")` + `setValue(forKey: "targets")` (`Router.swift:196`), attached via a
  `UIViewControllerRepresentable` whose `updateUIView` runs every render
  (`injectInTabDestinations.swift:151`).
- **Hand-rolled forward-swipe** with `DispatchQueue.main.asyncAfter` delays hardcoded to
  animation timings (`RedditForwardNavigationGesture.swift:76`).
- **Legacy `TabView(selection:){ .tabItem }` + custom `TabBarOverlay`** for the account
  switcher hit-area over the Me tab (`Tabber.swift:55`, `TabBarOverlay.swift:26`).
- Hardcoded column widths; global mutable `ScreenMetrics` geometry.

## Target architecture

Keep the routing **vocabulary** (`NavDest`) so the hundreds of `Nav.to(...)` / link-tap
call sites keep working. Replace the **storage + rendering** layer underneath.

1. **Lift `NavDest` to a top-level type** (`Navigation/NavDest.swift`) so it survives
   `Router`'s deletion. Mechanical rename `Router.NavDest` → `NavDest` across the app.

2. **One `@Observable` app navigator** (`AppNav`, replaces `Nav` + `Router`):
   - `selectedTab: Tab`
   - `posts: PostsNav` (3-column), `me/search: ColumnNav` (2-column),
     `inbox: StackNav`, `settings: SettingsNav`
   - Static facade preserved: `Nav.to`, `Nav.fullTo`, `Nav.back`, `Nav.resetStack`,
     `Nav.present`, `Nav.openURL` re-pointed at the new state.

3. **Selection-driven split surfaces** (the core fix). Posts becomes, in essence:
   ```swift
   NavigationSplitView(columnVisibility: $nav.columnVisibility) {
       sidebar                                   // List(selection: $nav.community)
   } content: {
       NavigationStack(path: $nav.contentPath) { feed(for: nav.community) }
           // List(selection: $nav.selectedPost)
   } detail: {
       NavigationStack(path: $nav.detailPath) { detail(for: nav.selectedPost) }
   }
   .navigationSplitViewStyle(.balanced)
   ```
   Both content and detail carry `.navigationDestination(for: NavDest.self)` (reuse
   `RouterDestinationView`). `NavigationSplitView` composes sidebar→content→detail into
   one stack when collapsed and splits it back when expanded — **we own none of that**.
   Deleted: `columnVisibility`/`preferredColumn` micromanagement, `focusContent/Detail`,
   `forwardRoutes`, `absorb*`, `record*`, `suppressNextRouterPopRecord`.

   `PostsNav` state: `community: CommunitySelection?` (sidebar), `selectedPost: Post.ID?`
   (content), `contentPath: [NavDest]` (pushes inside content column), `detailPath:
   [NavDest]` (pushes inside the open post). Detail root derives from `selectedPost`.

4. **`.sidebarAdaptable` tab shell** (`Tabber`):
   ```swift
   TabView(selection: $nav.selectedTab) {
       Tab("Posts", systemImage: "doc.text.image", value: .posts)   { PostsRoot() }
       Tab("Inbox", systemImage: "bell.fill",     value: .inbox)   { InboxRoot() }
       Tab("Me",    systemImage: "person.fill",    value: .me)      { MeRoot() }
       Tab("Search",systemImage: "magnifyingglass",value: .search, role: .search) { SearchRoot() }
       Tab("Settings", systemImage: "gearshape.fill", value: .settings) { SettingsRoot() }
   }
   .tabViewStyle(.sidebarAdaptable)
   ```
   Account switcher (was `TabBarOverlay` over the Me tab) relocates to a real control —
   long-press / `.contextMenu` on the Me root + a toolbar control — since the Me tab
   moves into the sidebar at regular widths.

## Deletions

- `Navigation/RedditForwardNavigationGesture.swift` (whole file)
- `Router.ViewControllerHolder`, `UINavigationController.addFullSwipeGesture` (private
  API), and `AttachViewControllerToRouterView` (`injectInTabDestinations.swift`)
- `RedditSplitNavigationModel` choreography → thin `PostsNav` / `ColumnNav`
- `components/TabBarOverlay/TabBarOverlay.swift` (account switcher relocated)
- Nav-layer usage of `ScreenMetrics` and `SwipeAnywhere`
- Eventually `Router` itself, once all surfaces are migrated

## Execution order (stays buildable; Xcode MCP build at each ✅)

1. **Foundation** — lift `NavDest` to top level; introduce `AppNav` + per-surface nav
   types alongside the existing `Nav`/`Router` (both compile). ✅
2. **Posts surface** — rebuild `AuroraRoot` on `AppNav.posts`; bridge `Nav.to` /
   contextual deep links into the new selections; swap Tabber's Posts tab. Other tabs
   stay on old code (still use `Router`). ✅
3. **Me / Search / Inbox / Settings** — migrate onto `ColumnNav` / `StackNav` /
   `SettingsNav`. ✅ after each.
4. **`.sidebarAdaptable` tab shell** — switch `Tabber` to `Tab(value:)` +
   `.sidebarAdaptable`; relocate the account switcher; delete `TabBarOverlay`. ✅
5. **Delete dead code** — `Router`, gesture files, private API, choreography. ✅
6. **Polish & verify** — dynamic column widths, `toolbarMinimizeBehavior` (SDK 27),
   deep-link tab-context preservation, retire nav-layer `ScreenMetrics`.

## Verification matrix (each surface)

- Compact iPhone: tab → sidebar pick → feed → post → push (user) → back, all native.
- Regular iPad: three columns visible; selection updates detail; back within detail.
- **Resize / fold / Split View drag / rotation**: open a post in regular, shrink to
  compact → the post stays open and back works; grow back → columns restore. (This is
  the failing case today.)
- Deep link (`winstonapp://` + clipboard) routes to the right column and preserves the
  current tab where sensible.
- `.sidebarAdaptable`: tab bar ↔ sidebar transition keeps selection; account switcher
  reachable in both.

## Known sharp edges

- iOS 18+ APIs (`Tab(value:)`, `.sidebarAdaptable`, `role: .search`) — fine on iOS 27.
- Sidebar `List(selection:)` deselects transiently when the `CachedSub` `@FetchRequest`
  re-syncs (noted at `AuroraRoot.swift:74`). New `PostsNav.community` must be a stable
  selection token, not derived from `CachedSub` identity churn.
- Theming: `.sidebarAdaptable` sidebar vs Aurora glass needs a design pass.
- Build only with the **Xcode 27 beta** toolchain (project targets iOS 27).
