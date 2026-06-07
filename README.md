# LunarCast

**Open source · free on the App Store** — [lunarcast.app](https://lunarcast.app) · [download for iPhone and iPad](https://apps.apple.com/us/app/lunarcast/id6761336207)

LunarCast is a simple, ad-free podcast player. Pick the shows you care about, skip algorithmic recommendations, and listen without clutter. The app is free with no in-app purchases.

Built-in feeds include Moonshots, Lex Fridman, Innermost Loop, and a curated collection of Elon Musk guest interviews. You can also add any podcast or newsletter-style RSS feed by URL.

## Features

- **Feed** — browse and play episodes from your selected podcasts
- **Newsletters** — follow text-first RSS publications (e.g. Substack)
- **Favorites** — save episodes for later
- **Playback** — speed control, sleep timer, and a mini player
- **Offline downloads** — listen without a connection
- **iCloud sync** — optional sync for favorites, custom feeds, playback progress, and preferences

Requires **iOS 17.0** or later (iPhone and iPad).

## For developers

This repository contains the **open source** source for LunarCast (internal project name: **moonmind**). Licensed under [MIT](LICENSE).

The Xcode project lives under `Moonmind/` (scheme `moonmind`, bundle ID `com.moonmind.moonmind`).

- SwiftUI + SwiftData, iOS 17+
- Agent workflows in Cursor can use the Xcode MCP setup described in [`AGENTS.md`](AGENTS.md)

### Local setup

1. Open `Moonmind/Moonmind.xcodeproj` in Xcode.
2. On first build, a run script copies `Moonmind/moonmind/Config/LocalSecrets.example.swift` → `LocalSecrets.swift` if the latter is missing.
3. **Optional — Podcast Index search fallback:** free keys at [podcastindex.org/account](https://podcastindex.org/account). Paste into `Moonmind/moonmind/Config/LocalSecrets.swift` (gitignored). iTunes search works without keys; Podcast Index is only used when iTunes returns nothing.

**If you previously cloned this repo:** rotate any Podcast Index credentials that were ever committed in git history, then update your local `LocalSecrets.swift`.

## Feedback

Found a bug or have a feature idea? Open an issue on GitHub or reach out through the App Store listing.
