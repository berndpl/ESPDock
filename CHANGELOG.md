# Changelog

## 0.2 (Build 3) — 2026-10-20

- Source: `3bc27f8c4ddb58f67acf183858f64fd2d7078afa`
- Marketing decision: minor — project-owned hardware assemblies and a third, transparent blue schematic style are substantial new capabilities; continue the global build counter after build 2.
- Notarization: Accepted (`67e6c3ec-0a50-4f4e-9a7d-621b82574920`)
- Developer ID: Bernd Plontsch (`DNKZNVGEK5`), preserving the Xcode-selected Team.
- Installed app: `/Applications/ESPDock.app`
- Archive: `/Users/berndplontsch/PARALocal/ESPDock/dist/ESPDock-0.2-build-3-macos-arm64.zip`
- Build date: `2026-10-20T10:31:33Z`
- Installation: signature, stapling, Gatekeeper, version, unchanged Release icon and canonical GUI launch verified.

### Changes

- Automatically load and watch complete hardware assemblies from a linked project's `hardware.json`.
- Render carrier boards, e-paper panels, cameras and batteries, including documented inter-component and B2B connections.
- Display malformed or incompatible manifests explicitly instead of silently guessing hardware.
- Repeated board clicks cycle Realistic, Blueprint and transparent Blue schematic styles; preserve the selected style, pin guides and wire highlighting.
- Preserve source-scanned radio hardware and show unknown power estimates when no verified component model exists.

## 0.1 (Build 2) — 2026-10-19

- Source: `f5b0e9af70d14165dd31347111ef88d7260d7a76`
- Marketing decision: unchanged — first changelog-backed install; retain the existing 0.1 baseline, with no prior release tags or notes establishing a different milestone.
- Notarization: Accepted (`521caea7-3c32-4ef4-8750-f932785a8b89`)
- Installed app: `/Applications/ESPDock.app`
- Archive: `/Users/berndplontsch/PARALocal/ESPDock/dist/ESPDock-0.1-build-2-macos-arm64.zip`

### Changes

- Native ESP32 detection, linked PlatformIO projects, firmware identity and USB build/deploy.
- Automatically paired, read-only Wi-Fi monitoring alongside USB logs and Copy Output.
- Project wiring diagrams with amplifier, speaker and switch cells, pin guides and selectable connections.
- Schematic-based project power estimates, reusable supply profiles and source-reference popovers.
- Direct project-folder opening in Finder, simplified supply controls and a centered disconnected state with bottom-aligned Wi-Fi status.
- Preserve the normal app icon and the Xcode-selected signing Team.
