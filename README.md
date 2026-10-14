# SpotLyrics Bar

SpotLyrics Bar is a native macOS menu bar app for showing Spotify synced lyrics while you work. The MVP focuses on a stable status-bar lyric line and a compact lyrics panel. A notch / Dynamic Island style card is reserved as an experimental v2 display mode.

## What It Does

- Shows the current Spotify lyric line in the macOS menu bar.
- Opens a compact, arrowless Spotify-style floating panel when you click the menu bar text.
- Reads the current Spotify track, artist, album, duration, playback position, and play/pause state through AppleScript.
- Automatically sniffs Spotify on launch and searches/syncs lyrics without requiring a manual search click.
- Searches synced LRC lyrics from LRCLIB first, then uses a scored NetEase fallback when LRCLIB has no trusted synced result.
- Supports Spotify podcast episodes with transcript-backed synced text for English learning.
- Searches podcast transcripts from Apple/iTunes RSS feeds and publisher transcript links, accepts `.lrc`, `.vtt`, `.srt`, and `.txt`, and can AI-transcribe RSS or imported podcast audio in timed chunks.
- Uses cached lyrics before making a network request.
- Rejects low-confidence lyric matches instead of showing likely wrong lyrics.
- Shows trusted plain lyrics as an unsynced fallback instead of pretending they are synced.
- Supports manual `.lrc` import.
- Supports manual podcast transcript import / paste from `.lrc`, `.vtt`, `.srt`, or `.txt`.
- Supports per-song lyric offset from `-3s` to `+3s`.
- Saves cache and offsets after restart.
- Includes optional AI English learning: click `Explain` for slang, idiom, tone, culture notes, and natural Chinese explanation.
- Stores AI API keys in macOS Keychain, not UserDefaults.
- Provides Quit from the floating panel and the status-bar right-click menu.

## Project Structure

```text
SpotLyricsBar
├── Package.swift
├── README.md
├── Scripts
│   ├── package-app.sh
│   ├── run-checks.sh
│   ├── run-debug.sh
│   └── UnitChecks.swift
└── Sources
    └── SpotLyricsBar
        ├── APIKeychainStore.swift
        ├── AppDelegate.swift
        ├── AppState.swift
        ├── DesignSystem.swift
        ├── EnglishLearningService.swift
        ├── LLMSettingsStore.swift
        ├── LRCLibService.swift
        ├── LyricsCacheService.swift
        ├── LyricsPanelView.swift
        ├── LyricsSyncEngine.swift
        ├── Models.swift
        ├── SettingsStore.swift
        ├── SettingsView.swift
        ├── SpotifyPlaybackService.swift
        ├── TextNormalizer.swift
        └── main.swift
```

## Requirements

- macOS 14 or newer.
- Spotify desktop app installed.
- Apple Command Line Tools or Xcode with Swift 6.
- Internet access for first-time lyric search.

If `swift build` reports an SDK/toolchain mismatch, install or switch to a matching Xcode / Command Line Tools version:

```bash
xcode-select --install
```

If full Xcode is installed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## One-Command Run

From this folder:

```bash
./Scripts/run-debug.sh
```

You should see `SpotLyrics` in the macOS menu bar. Start Spotify and play a song.

On first use, macOS may ask for Automation permission. Allow SpotLyrics Bar to control/read Spotify. The app only reads the current playback state.

## Build a `.app`

```bash
./Scripts/package-app.sh
```

The app is created at:

```text
dist/SpotLyrics Bar.app
```

Open it from Finder. Because this is a local unsigned build, macOS may show a security warning. Use:

1. Right click `SpotLyrics Bar.app`.
2. Choose `Open`.
3. Confirm you want to open it.

For a real public release, sign and notarize the app with an Apple Developer ID.

## How to Use

1. Open Spotify.
2. Play a normal music track.
3. SpotLyrics Bar automatically detects the track, searches lyrics, and syncs the current line.
4. Click the menu bar text to open the lyrics panel.
5. Use offset buttons if lyrics feel early or late.
6. Use `Import .lrc` if online lyrics are missing.
7. Use `Hide Lyrics` when you temporarily want a quiet menu bar.

For podcasts:

1. Play a Spotify podcast episode.
2. SpotLyrics Bar searches publisher transcript sources and syncs the transcript like lyrics.
3. If no public transcript is found, SpotLyrics tries the podcast RSS enclosure audio with AI transcription when your provider is configured.
4. `AI transcribe` can also run on a local podcast audio file. Spotify does not expose downloadable episode audio through AppleScript, so the automatic path uses the publisher RSS audio when available.

## AI English Learning

AI is optional. Lyrics still work with no AI provider configured.

Open `AI Settings` from the panel and fill:

- Provider Name: `openai`, `deepseek`, `anthropic`, `timi_cc`, or any custom name.
- API Request URL: for example `https://api.openai.com/v1` or `https://timicc.com/v1`.
- Model Name: for example `gpt-5.5`, `deepseek-chat`, or `claude-sonnet-4`.
- Wire API: `OpenAI Responses`, `OpenAI Chat Completions`, or `Anthropic Messages`.
- API Key: saved in macOS Keychain.

The app does not automatically send every lyric line to AI. It sends only the clicked/current line, nearby context, song title, and artist when you click `Explain`. The explanation card stays pinned to the selected line while playback lyrics continue syncing.

If a provider supports OpenAI-compatible Chat Completions but not Responses, SpotLyrics Bar tries a compatible fallback automatically.

Podcast AI transcription uses the same provider settings when the provider exposes an OpenAI-compatible `/audio/transcriptions` endpoint. The automatic path prefers `gpt-4o-transcribe-diarize` for timed high-accuracy segments, falls back to `gpt-4o-transcribe` with chunk-based timing, and only then falls back to `whisper-1`.

## Privacy

- The app reads only the current Spotify playback information through local AppleScript.
- Lyric search sends song title, artist, and album to LRCLIB.
- Podcast transcript search sends show / episode names to Apple/iTunes lookup and fetches publisher RSS / transcript pages when available.
- AI learning sends only the selected lyric context to the provider you configure.
- AI transcription sends the podcast RSS audio or the audio file you explicitly import to the provider you configure.
- API keys are stored in macOS Keychain.
- Logs must not print API keys.
- Spotify OAuth is not required for the MVP.

## Error States

- `Open Spotify to start lyrics`: Spotify is not running.
- `Paused`: Spotify is paused.
- `Lyrics not found`: no trusted synced lyrics were found.
- `Lyrics source unavailable — retrying`: the lyric source or network failed; the app will retry automatically.
- `Unsynced lyrics found`: trusted plain lyrics were found, but no timestamped LRC was available.
- `Searching transcript...`: Spotify is playing a podcast and SpotLyrics is looking for transcript-backed synced text.
- `Need podcast transcript`: no automatic transcript source was found yet; import/paste a transcript or import an audio file for AI transcription.
- `Lyrics match uncertain`: a candidate existed, but confidence was too low.
- `Unsupported content`: Spotify is playing something like an ad or local file with incomplete metadata.
- `Allow automation access to Spotify`: macOS Automation permission is missing.

## Debug Guide

Run the app from Terminal:

```bash
./Scripts/run-debug.sh
```

Common fixes:

- No Spotify detected: open Spotify desktop app, not only the web player.
- Permission issue: open `System Settings > Privacy & Security > Automation` and allow SpotLyrics Bar to access Spotify.
- No lyrics: try another song, click `Retry`, or import a `.lrc` file.
- App appears stuck: right-click the status-bar text and choose `Refresh Lyrics` or `Quit SpotLyrics Bar`.
- Wrong timing: use offset buttons in the panel.
- Network issue: cached lyrics still work; new songs need internet.
- Menu bar too crowded: reduce max length in `Settings`.

## Checks

Run lightweight algorithm checks:

```bash
./Scripts/run-checks.sh
```

Covered:

- LRC parser with multiple timestamps.
- VTT/SRT podcast transcript conversion.
- Spotify episode parsing and podcast transcript routing.
- Floating panel placement below the clicked lyric capsule.
- Current-line sync with global latency and per-track offset.
- Previous/next lyric context.
- Title cleaning and similarity basics.

`swift test` is intentionally not required because some Command Line Tools installs do not include `XCTest` or Swift Testing.

## MVP Status

Completed:

- Native macOS menu bar app.
- Arrowless modern floating panel instead of the default old-style `NSPopover` callout.
- Spotify AppleScript integration.
- Dynamic polling interval: playing, paused, Spotify not running.
- Auto Spotify sniffing and auto lyric search on launch / song change.
- LRCLIB synced lyrics search.
- NetEase backup search with the same score threshold.
- Plain-lyrics fallback with explicit unsynced state.
- Candidate confidence scoring.
- Cache and per-track offset persistence.
- LRC parser and sync engine.
- Lyrics panel with current and nearby lines.
- Manual `.lrc` import.
- Podcast transcript search, import, paste, and AI transcription entry point.
- Hide/show lyrics.
- Right-click status menu with Refresh, Hide/Show, and Quit.
- Settings panel.
- AI provider settings and Keychain API key storage.
- Optional Explain current line flow.
- Click any visible lyric line to explain that exact line without pausing lyric sync.
- Release `.app` packaging script.
- Lightweight algorithm checks.

Not completed / v2:

- Real notch/Dynamic Island card rendering.
- Spotify Web API OAuth fallback.
- Manual candidate picker for low-confidence lyrics.
- Start at login.
- Signed and notarized public release.
- Full UI automation tests.

## Performance Notes

- Playing: polls Spotify every about `400ms`.
- Paused: polls every about `1500ms`.
- Spotify not running: polls every about `4000ms`.
- Menu bar text updates only when the current lyric line changes.
- Lyrics search is one request per track key unless user retries.
- Network timeout is `5s`.
- Cache is stored under `~/Library/Application Support/SpotLyricsBar/lyrics-cache.json`.

## QA Checklist

- First launch shows `SpotLyrics`.
- Spotify closed shows clear empty state.
- Spotify playing shows track and lyric after lookup.
- App launch while Spotify is already playing auto-searches lyrics without clicking `Retry`.
- Pause displays paused state.
- Switching songs resets lyrics and searches again.
- Seeking playback resyncs current lyric line on next poll.
- Seeking playback briefly shows `Syncing…` before the corrected lyric line.
- Missing lyrics does not crash.
- Low-confidence lyrics are not auto-shown.
- Offset buttons update immediately and persist.
- Imported `.lrc` displays and caches.
- Hide Lyrics keeps menu bar quiet.
- Dark and light macOS appearances remain readable.
- External displays do not affect menu bar mode.
- Notch Card is not required for MVP.
- Network offline uses cache if available.
- Restart preserves cache, offset, settings, and AI provider config.

## PM Review

- Lyrics source instability: handled with clear source display, cache, retry, and manual `.lrc` import.
- Backup source: LRCLIB remains first, NetEase is used only after scoring verifies title/artist/duration.
- Wrong lyrics risk: handled with confidence threshold and low-confidence rejection.
- Offset pain: handled with quick panel buttons and per-song persistence.
- Menu bar space: handled with max length setting and truncation.
- Spotify closed: handled with clear empty state and auto recovery.
- External display / notch risk: MVP does not depend on notch; v2 mode is experimental.
- Non-developer user: one-command run, package script, and troubleshooting are documented.
- Temporary hiding: handled with `Hide Lyrics`.
- CJK lyrics: Swift strings and LRC parser support Unicode; display truncation uses character count.
- Podcast learning: transcript-backed display reuses the lyrics sync engine, offset controls, cache, and Explain flow.
- Ads / local files: incomplete metadata falls back to unsupported-content state.
- English learning: optional `Explain` flow with concise Chinese explanation.
- Provider flexibility: custom base URL, model, wire API, reasoning effort, and Keychain key storage.

## Known Limits

- LRCLIB coverage varies by song and region.
- Spotify AppleScript depends on the Spotify desktop app and macOS Automation permission.
- The local `.app` is unsigned unless you sign it yourself.
- AI response quality depends on the provider and model configured by the user.
