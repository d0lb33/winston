# Tap Target Debugging and Fix Plan

## Goal

Make taps feel deterministic across post cards and comment rows:

- Tapping a comment header/body collapses or expands the intended comment.
- Tapping comment author, votes, media, spoiler controls, or links performs that specific action.
- Tapping post title/card opens the post.
- Tapping post media opens media only when the tap is actually inside the visible media region.
- No invisible or oversized hit region steals taps from nearby content.

## Current Symptoms

- Some comment taps do not collapse the comment.
- There may be a dead gap between comment header and comment body.
- Post card touch targets feel inconsistent.
- Sometimes a tap intended for title/card appears to open full-screen media.

## Likely Causes

1. **Competing gestures inside a `List`**
   Comment rows use native swipe actions, context menus, header taps, body-overlay taps,
   child author taps, vote buttons, and media taps. A small horizontal drift can let the
   `List`/swipe recognizer win instead of the collapse tap.

2. **Clear-background hit-test gaps**
   Comment collapse currently uses region-specific taps plus a clear fallback background.
   Clear backgrounds inside `List` rows can be hard to reason about, especially around
   padding, spacing, and child views that have their own hit testing.

3. **Oversized media hit regions**
   Feed media and post-detail media go through the media presenter stack. If the media view
   reports a larger frame than the visible image/video, it can steal taps that visually look
   like title/card taps.

4. **State suppression**
   Comment collapse intentionally ignores taps while swipe actions are presented. If the
   swipe presentation state stays true briefly or gets stuck, a normal tap can be dropped.

## Phase 1: Instrument Before Fixing

Add a temporary tap-source logger for comment collapse:

```swift
private func toggleCollapse(source: String) {
  AppDiagnostics.shared.breadcrumb(
    "Comment collapse tap",
    metadata: [
      "source": source,
      "comment": row.id,
      "collapsed": "\(row.isCollapsed)",
      "swipePresented": "\(swipePresented)"
    ]
  )
  guard !swipePresented else { return }
  model.toggleCollapse(row.id)
}
```

Call it from distinct sources:

- `header`
- `bodyText`
- `fallback`
- `authorWhenCollapsed`
- `accessibility`

Add similar lightweight logging for post/media taps:

- `postCard`
- `postTitle`
- `postBody`
- `feedMedia`
- `postDetailMedia`
- `subreddit`
- `author`
- `vote`

The first question is whether the tap does not arrive, arrives at the wrong target, or
arrives but is suppressed.

## Phase 2: Visual Hit Map

Add a temporary diagnostics flag that overlays translucent hit regions:

- Comment header: orange
- Comment body text: yellow
- Comment fallback/background: red
- Comment author/profile: blue
- Vote controls: green
- Media: purple
- Post card/title/body: pink
- Subreddit/author links: blue

Use the existing diagnostic overlay pattern, but make it draw the actual hit rectangles
clearly enough to inspect on device.

The goal is to answer visually:

- Is there a real gap between the comment header and text hit regions?
- Does the fallback region cover the row padding/spacing?
- Does the media hit rectangle overlap the title/body?
- Do vote/author hit boxes extend farther than expected?

## Phase 3: Frame Logging

For the suspicious regions, log global frames while diagnostics are enabled:

- comment row frame
- comment header frame
- comment body text frame
- comment fallback/background frame
- feed card frame
- feed title frame
- feed media frame
- post-detail title frame
- post-detail media frame

This can be done with `onGeometryChange` or a local preference-key helper. Keep it behind
a diagnostics flag so it does not run in normal use.

## Phase 4: Isolation Toggles

Add temporary runtime toggles to disable one interaction class at a time:

- Disable comment swipe actions.
- Disable comment context menu.
- Disable comment author/profile tap.
- Disable comment media hit testing.
- Disable feed media hit testing.
- Disable post card outer tap.

Expected conclusions:

- If comment collapse becomes reliable when swipe actions are disabled, the swipe recognizer
  is competing with tap recognition.
- If title taps stop opening media when media hit testing is disabled, media is stealing.
- If gaps remain even with child interactions disabled, the fallback hit region is wrong.

## Candidate Fixes

### Comment Rows

Prefer one explicit collapse hit layer for the whole non-control row area.

Options:

1. Replace the clear-background fallback with an explicit row-level overlay that excludes
   known controls where possible.
2. Make the header/body collapse tap use `highPriorityGesture`, but keep author, vote,
   spoiler, link, and media controls as explicit child controls.
3. Add a small visible collapse/expand chevron button in the header as a guaranteed target.
4. Reset `swipePresented` defensively after a short delay when swipe actions close.
5. If native swipe actions are the main conflict, consider disabling comment swipe actions
   in the native comment path or moving those actions to context menus/explicit buttons.

### Post Cards

1. Constrain media hit testing to the actual visible media bounds.
2. Ensure `MediaPresenter` and wrappers do not retain a larger invisible frame.
3. Give the title/body/card their own diagnostic tap sources.
4. Decide product behavior for feed cards:
   - Media tap opens media.
   - Non-media card tap opens post.
   - Subreddit/author/vote controls own only their visible target plus a reasonable minimum
     hit area.

## Tests to Add After Root Cause Is Known

### Unit / Model Tests

Add `CommentTreeModel` tests:

- Build root A with replies B/C and root D.
- Assert initial rows are A, B, C, D.
- Collapse A.
- Assert B/C disappear, A and D remain.
- Expand A.
- Assert B/C return in order.

### Fixture UI Tests

Add a fixture post-detail E2E mode with mock post/comments and stable accessibility IDs:

- Tap root comment header center: child reply disappears.
- Tap body text center: child reply disappears.
- Tap between header and body: should collapse if that region is intended to collapse.
- Tap author: opens profile / does not collapse when expanded.
- Tap vote: votes / does not collapse.
- Tap media: opens media.

Add a fixture feed-card E2E mode:

- Tap title: opens post.
- Tap text/body: opens post.
- Tap visible media: opens media.
- Tap just above media: does not open media.
- Tap author/subreddit: opens author/subreddit only.

## Done Criteria

- No visible dead zones in intended comment collapse regions.
- Diagnostic tap logs match the visual region tapped.
- Media no longer steals taps outside its visible bounds.
- Swipe actions no longer suppress normal taps after dismissal.
- Comment collapse has model tests and at least one fixture UI test.
- Feed-card title/media behavior has at least one fixture UI test.
