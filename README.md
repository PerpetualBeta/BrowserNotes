# Browser Notes

A macOS menu bar app that lets you attach notes to any web page in any browser. Notes appear automatically when you revisit a page, and you can browse, filter, and edit all your notes from a single keyboard shortcut.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/BrowserNotes/releases/latest/download/BrowserNotes.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/BrowserNotes/releases/latest)** — unzip and drag `BrowserNotes.app` to your Applications folder.

After installation:

1. Launch Browser Notes — a globe icon appears in the menu bar
2. Grant Accessibility permission when prompted

## How It Works

Browser Notes reads the current URL from your browser's address bar using the macOS Accessibility API. No browser extensions, no JavaScript injection, no network requests — it works with any browser that exposes a standard address bar.

Notes are stored locally in a SQLite database. Nothing leaves your machine.

### Adding a Note

Press **⌃⌥⇧⌘N** (Hyper+N) while a browser is in focus to open the Add Note panel. Type your note — use `#hashtags` to categorise — and press Return.

### Page Notes HUD

When you navigate to a page that has notes, a floating HUD appears showing all notes for that URL. Each note displays its text, hashtag pills, and a relative timestamp. Click the pencil icon on any note to edit it.

The HUD:
- Appears automatically on pages with notes
- Dismisses when you switch to a page without notes, open a new tab, or leave the browser
- Re-appears when you return to the browser
- Stays put when you interact with it (resize, edit)
- Grows downward when new notes are added

### Notes Browser

Press **⌃⌥⇧⌘H** (Hyper+H) to open the Notes Browser — a searchable list of all your notes across all pages. Type to filter by note text, URL, or hashtag. Navigate with arrow keys and press Return to open the page in your current browser.

| Key | Action |
|-----|--------|
| **↑** / **↓** | Navigate notes |
| **Return** | Open page in browser |
| **Escape** | Dismiss |
| **Type** | Filter notes |

### Editing Notes

Click the pencil icon on any note in the Page Notes HUD to open it for editing. The original timestamp is preserved.

### Hashtags

Include `#hashtags` in your notes to categorise them. Tags are rendered as pills in the Page Notes HUD and are searchable in the Notes Browser.

### Supported Browsers

Safari, Chrome, Edge, Firefox, Arc, Brave, Opera, Vivaldi, Orion, Chromium, Zen, SigmaOS, Waterfox, LibreWolf, Mullvad Browser, and Tor Browser.

## Settings

Right-click the globe icon and choose **Settings...** to configure:

- **Notes Browser hotkey** — customise the global hotkey (default: ⌃⌥⇧⌘H)
- **Add Note hotkey** — customise the global hotkey (default: ⌃⌥⇧⌘N)
- **Accessibility permission** — status display and grant button
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)
- **Launch at Login** — start automatically when you log in
- **Auto-update** — check for new versions on a configurable schedule

## Permissions

- **Accessibility** — required to read browser URLs and detect keyboard shortcuts. macOS will prompt on first use.

## Architecture

| Component | Purpose |
|-----------|---------|
| `BrowserNotesEngine.swift` | CGEvent tap for hotkeys, URL polling, HUD lifecycle |
| `AccessibilityReader.swift` | Reads browser URL bar via AX tree traversal |
| `AddNoteHUD.swift` | Vibrancy glass panel for adding and editing notes |
| `PageHighlightsHUD.swift` | Auto-appearing HUD with note cards, pills, edit buttons |
| `HighlightHUDPanel.swift` | Notes Browser with filter, table view, delete, navigate |
| `HighlightStore.swift` | Thread-safe SQLite store with URL normalisation and caching |
| `HighlightModels.swift` | `SavedNote` model with computed hashtag extraction |
| `SharedTypes.swift` | Browser bundle IDs, HUD panel delegate, tab navigation |

## Data Storage

Notes are stored in `~/Library/Application Support/BrowserNotes/notes.db`. URLs are normalised (fragments stripped, trailing slashes cleaned) so notes survive minor URL variations.

## Building from Source

Browser Notes uses Swift Package Manager. No Xcode project is required.

```bash
git clone https://github.com/PerpetualBeta/BrowserNotes.git
cd BrowserNotes
./build.sh
open _BuildOutput/BrowserNotes.app
```

---

Browser Notes is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
