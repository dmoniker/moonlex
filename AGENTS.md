# Agent notes (Moonlex + Xcode MCP)

Use this when working from **Cursor** with **Xcode MCP** enabled ([Apple: external agents + Xcode](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode)).

## Before you use Xcode-backed tools

1. Open **`Moonlex/Moonlex.xcodeproj`** in **Xcode** and leave it running.
2. In Xcode **Settings → Intelligence**, keep **“Allow external agents to use Xcode tools”** turned **on** (Model Context Protocol).
3. In **Cursor → Settings → MCP**, ensure the **`xcode`** server listed from this project’s `.cursor/mcp.json` is **enabled** (project MCP may need to be toggled on once).

## Project pointers

- **Scheme:** `Moonlex`
- **iOS:** 17.0+ · SwiftUI · SwiftData
- **Bundle ID:** `com.moonlex.Moonlex`
- **RSS sources:** built-in Moonshots + Lex Fridman; user can add more via RSS URL

## If something fails

- **`xcode` MCP shows “Error” in Cursor:** `mcpbridge` exists only in **full Xcode**, not Command Line Tools. Run  
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`  
  then check `xcrun --find mcpbridge` prints a path. Restart Cursor’s MCP or toggle the **xcode** server off/on.
- Confirm **`xcode-select -p`** points at **Xcode.app** (not `/Library/Developer/CommandLineTools`).
- Re-open the project in Xcode after major scheme or target changes.
