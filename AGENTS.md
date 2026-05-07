# EqualEase Agent Guide

EqualEase is a macOS system-wide equalizer app. These instructions apply to agents working in this public repository.

## Start Here

Before substantial implementation work, read the public project context in this order:

1. `README.md` — product overview, build steps, and licensing stance.
2. `docs/product-sense.md` — product intent, priorities, and non-goals.
3. `docs/design.md` — architecture, module boundaries, UI model, persistence, and failure modes.
4. Relevant feature docs in `docs/`, especially `docs/audio-routing.md`, `docs/local-network.md`, `docs/automation.md`, and `docs/testing.md`.

Private release planning, App Store operations, source screenshots, and historical planning artifacts are intentionally kept outside this public repository.

## Product Guardrails

- EqualEase is system-wide. Do not design it as an in-app audio player.
- EqualEase is a real, focused Mac app: simple by design, not a prototype.
- First-release EQ is a simple 10-band graphic equalizer.
- First-release preset precedence is remembered active-app preset, then selected default preset.
- Persisted device-rule data can remain internally, but device-specific preset rules are hidden and ignored while the product model is reconsidered.
- Smart app switching is learned from user choices; do not add built-in third-party app rules for the first release.
- Audio and settings should stay local unless a future public design explicitly says otherwise.

## Planning and Specification Workflow

For public changes, prefer small focused issues, clear pull requests, and documentation updates that describe user-visible behavior. Keep implementation and documentation coherent, especially when changing audio routing, permissions, privacy behavior, or local-network remote control.

When a change is substantial:

- Explain the user-facing behavior and non-goals before implementation.
- Keep architecture boundaries clear and testable.
- Update relevant public docs before considering the work complete.
- Prefer observable acceptance criteria over implementation-only checklists.

## Xcode MCP Access

When Xcode project work begins, prefer Xcode's built-in MCP server if available. This repository's agent harness may not support MCP directly, so wrap the MCP server with `mcp2cli` when needed.

Setup notes:

1. In Xcode, open Settings > Intelligence.
2. Under Model Context Protocol, enable “Allow external agents to use Xcode tools.”
3. Open the EqualEase project in Xcode before using the bridge.
4. Apple's documented MCP command is `xcrun mcpbridge`.
5. For this harness, use `mcp2cli` over stdio, for example: `uvx mcp2cli --mcp-stdio "xcrun mcpbridge" --list`.
6. If useful, bake a wrapper later, for example: `uvx mcp2cli bake create xcode --mcp-stdio "xcrun mcpbridge"` and optionally `uvx mcp2cli bake install xcode`.

Use Xcode MCP for Xcode-specific actions such as project introspection, build/run integration, and IDE-managed project changes. Continue using normal CLI tools for plain file edits, git, and tests when they are sufficient.

## Git Hygiene

- Prefer conventional commits.
- Keep planning/documentation changes separate from implementation changes when practical.
- Do not commit local build products, personal tool state, DerivedData, `.DS_Store`, or signing artifacts.
