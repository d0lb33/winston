# Tap Target Fix — RESOLVED

The deterministic tap-target issues are fixed. This file records the final approach (it
supersedes the original instrument-first investigation plan).

## What was wrong

1. **Comments didn't collapse on most of the row.** The collapse hit area sat *inside* the
   thread-rail indent gutter and the row's 16pt horizontal `listRowInsets`, so the left gutter
   and the side padding were dead zones. There were also three overlapping collapse hit layers
   (header `onTapGesture`, an inner clear `.background`, and a clear overlay *on the markdown
   text* inside `CommentBodyNative`).
2. **Media stole taps.** `GalleryThumb` + `ImageMediaSinglePreview` exposed a hit region larger
   than the visible image (a tappable `Color.clear` measurement background, plus an outer
   `.contentShape(Rectangle())` on the feed card's `mediaBlock`), so taps around/above the image
   opened fullscreen instead of the post.
3. **Post body collapse** put `onTapGesture` directly on the `Markdown` view.

## What was done

- **Comments — one full-row collapse target.** `CommentRowView` now sets `listRowInsets` to 0,
  folds the 16pt inset into the content, and makes the WHOLE row a single collapse tap target
  with `.contentShape(Rectangle()).onTapGesture { toggleCollapse() }` (comment rows only). A tap
  anywhere — the indent gutter, the side padding, empty header space, or plain body text —
  collapses/expands, because those areas have no inner gesture and fall to this one. The real
  controls (author, votes, media, links, spoiler) are deeper child gestures and win their own
  taps. The header tap, inner clear background, and on-text overlay were removed
  (`CommentBodyNative` is called with `onTextTap: nil`). No gesture is attached inside
  `CommentBodyNative`, preserving the fast-collapse performance property.
- **Media hit region = visible image only.** `ImageMediaPost` makes the `Color.clear`
  measurement background `.allowsHitTesting(false)`; the Aurora feed card's `mediaBlock` drops
  its outer `.contentShape(Rectangle())`. Behavior kept: the visible image opens fullscreen when
  `isMediaTappable` is on; everything else opens the post.
- **Post body collapse** uses a clear `.background` collapse layer (no gesture on the `Markdown`
  view) in `PostHeaderNative` + `AuroraPostDetail`; links still open.

## Tests

- Unit: `winstonTests/CommentTreeModelTests.swift` (flatten / collapse / expand / hiddenReplyCount).
- Fixture UI: `--winston-taptarget-e2e` launch gate → `winston/Navigation/TapTargetE2EHarness.swift`
  renders the REAL `CommentRowView` + `AuroraPostCardRow` with mock data;
  `winstonUITests/TapTargetE2ETests.swift` taps the gutter / padding / body / author / vote /
  link and the card title, asserting collapse vs. control-wins vs. open-post.
