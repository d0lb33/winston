# Agent Instructions

- For Xcode projects, use the Xcode MCP tools for builds whenever they are available. Prefer `mcp__xcode.BuildProject` and `mcp__xcode.GetBuildLog` over shelling out to `xcodebuild` so diagnostics match the active Xcode workspace, scheme, and destination.
- If the Xcode MCP is unavailable or cannot attach to a workspace tab, state that clearly and fall back to the best available local build or parse check.
