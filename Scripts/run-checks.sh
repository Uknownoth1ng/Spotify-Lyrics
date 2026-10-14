#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/checks
swiftc \
  Sources/SpotLyricsBar/Models.swift \
  Sources/SpotLyricsBar/TextNormalizer.swift \
  Sources/SpotLyricsBar/LyricsSyncEngine.swift \
  Sources/SpotLyricsBar/FloatingPanelPlacement.swift \
  Sources/SpotLyricsBar/SpotifyPlaybackParser.swift \
  Sources/SpotLyricsBar/PodcastTranscriptService.swift \
  Sources/SpotLyricsBar/APIKeychainStore.swift \
  Sources/SpotLyricsBar/LLMSettingsStore.swift \
  Sources/SpotLyricsBar/AITranscriptionService.swift \
  Scripts/UnitChecks.swift \
  -o .build/checks/SpotLyricsBarChecks
.build/checks/SpotLyricsBarChecks
