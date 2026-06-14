# Agent Instructions

- For Xcode projects, use the Xcode MCP tools for builds whenever they are available. Prefer `mcp__xcode.BuildProject` and `mcp__xcode.GetBuildLog` over shelling out to `xcodebuild` so diagnostics match the active Xcode workspace, scheme, and destination.
- If the Xcode MCP is unavailable or cannot attach to a workspace tab, state that clearly and fall back to the best available local build or parse check.
- Changes that belong in the Swift Reddit POC library rather than the Winston app are acceptable. When a bug or API shape issue is better fixed in `RedditAPIResearch/SwiftRedditPOC`, make the change there and update the app integration as needed instead of working around it only in Winston.
- When diagnosing Reddit operation behavior, feel free to use RedditOperationInspect with `/Users/jdolbe1/Documents/Development/winston/RedditAPIResearch/SwiftRedditPOC/.session.json`. If the session is expired or invalid, stop and tell the user to fix the session instead of trying to work around it.

## Terminal helpers for testing (RedditAPIResearch/SwiftRedditPOC)

These CLIs let agents exercise the real Reddit GraphQL the app uses, from the terminal, without the simulator. They all read `.session.json` (a live session captured by `reddit-session-capture`; never print or commit it). Run from the package dir, e.g. `cd RedditAPIResearch/SwiftRedditPOC`.

- **`reddit-comment-tree`** — open a post and load its comment forest, including nested / nested-nested "more" continuations. Use it to reproduce and diagnose comment-tree bugs (it prints API ground-truth, so you can tell whether a bug is in the response or in the app's assembly in `RedditWire.adaptCommentTrees` / `nestComments` / `moreReplies`).
  ```sh
  swift build -c release --product reddit-comment-tree
  BIN=.build/release/reddit-comment-tree   # or `swift run reddit-comment-tree …`
  "$BIN" 1u4och7                                   # post id, t3_ fullname, or a reddit URL
  "$BIN" 1u4och7 --max-depth 2 --resolve-more 3    # force + recursively resolve nested "more" stubs
  "$BIN" --comment-id oreg58u --json               # single-thread (deep-link) context, JSON for parsing
  "$BIN" --help
  ```
  Output flags surface likely nested-comment bugs: `orphans` (a reply whose parent isn't in the batch — e.g. a deleted comment returned with a nil id; the app may drop/re-root these), `depthGaps`, `tooDeepStubs` (API can't count — these are "continue thread" continuations), and `cursorLoops` (a continuation re-emitted an already-consumed cursor → cursor pagination dead-ends; resolve these by deep-linking to the parent comment, not paginating).
- **`reddit-search-inspect`** — time/inspect search panes (`--operation dynamic --pane communities|posts|people <query>`); useful for search-performance work.
- **`reddit-operation-inspect`**, **`reddit-profile-inspect`**, **`reddit-media-inspect`** — generic operation / profile / media inspectors.
- **`reddit-session-capture --out .session.json`** — refresh the session if a tool reports auth failures.
