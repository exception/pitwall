# Pitwall

Every agent, one wall. A native macOS canvas for running many AI coding agents
side by side: real terminals (libghostty) on an infinite canvas, live agent
status, approvals, worktrees, links between agents, and Pitwall Remote for iPhone.

## Layout

| Path | What |
|---|---|
| `Pitwall/` | macOS app (AppKit + SwiftUI) |
| `CLI/` | `pitwall` helper: session service, attach client, hooks, MCP server, CLI |
| `Shared/` | Code shared by the app, helper and iOS app (paths, wire formats, Remote protocol) |
| `iOS/` | Pitwall Remote (SwiftUI) |
| `remote-web/` | JS implementation of the Remote protocol (interop tests; future web client) |
| `docs/` | Specs (`remote-protocol.md`) |
| `scripts/` | `bootstrap.sh`, `ui-test.sh` |

## Build

    scripts/bootstrap.sh          # one time: Ghostty libs, web assets, Xcode project
    xcodebuild -scheme Pitwall build
    scripts/ui-test.sh            # end-to-end UI scenarios in an isolated instance

## Licenses

Pitwall embeds Ghostty (MIT). It bundles Ghostty's shell-integration scripts,
some of which are GPLv3; review before commercial distribution.
