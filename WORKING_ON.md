# What I’m working on

**LunarCast** ([free on the App Store](https://apps.apple.com/us/app/lunarcast/id6761336207)) is an iOS 17+ podcast app (SwiftUI, SwiftData; internal project name **moonmind**) for following podcasts and newsletter-style RSS feeds. Built-in sources include Moonshots and Lex Fridman; users can add any feed by URL.

Core experience: a tabbed home (Feed, Newsletters, Favorites), episode detail and playback, optional offline downloads, sleep timer, and a mini player. SwiftData persists catalog and user data, with optional **iCloud / CloudKit** sync for saves, custom feeds, playback progress, and preferences.

The Xcode project lives under `Moonmind/` (scheme `moonmind`, bundle `com.moonmind.moonmind`). Agent workflows in Cursor can use the **Xcode MCP** setup described in `AGENTS.md`.
