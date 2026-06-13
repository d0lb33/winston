# Agent Instructions

- For Xcode projects, use the Xcode MCP tools for builds whenever they are available. Prefer `mcp__xcode.BuildProject` and `mcp__xcode.GetBuildLog` over shelling out to `xcodebuild` so diagnostics match the active Xcode workspace, scheme, and destination.
- If the Xcode MCP is unavailable or cannot attach to a workspace tab, state that clearly and fall back to the best available local build or parse check.
- Changes that belong in the Swift Reddit POC library rather than the Winston app are acceptable. When a bug or API shape issue is better fixed in `RedditAPIResearch/SwiftRedditPOC`, make the change there and update the app integration as needed instead of working around it only in Winston.
- When diagnosing Reddit operation behavior, feel free to use RedditOperationInspect with `/Users/jdolbe1/Documents/Development/winston/RedditAPIResearch/SwiftRedditPOC/.session.json`. If the session is expired or invalid, stop and tell the user to fix the session instead of trying to work around it.
