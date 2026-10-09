# Inkwell

A minimalist, Typora-style live-preview Markdown editor built with SwiftUI. One codebase, one target, two destinations: **macOS 15+** and **iPadOS 18+**.

**Designed and Architected by: Phillip Escandon**

## Setup

Requirements: Xcode 27, Swift 6, `xcodegen` (`brew install xcodegen`).

```sh
cd typoraClone
xcodegen generate            # regenerates Inkwell.xcodeproj from project.yml
xcodebuild -scheme Inkwell -destination 'platform=macOS' build
xcodebuild -scheme Inkwell -destination 'generic/platform=iOS Simulator' build
```

The `.xcodeproj` is generated and git-ignored; `project.yml` is the source of truth. Signing is ad-hoc ("Sign to Run Locally") so the project builds with no Apple team. To run on a physical iPad, set `DEVELOPMENT_TEAM` in `project.yml` and switch `CODE_SIGN_STYLE` to `Automatic`.

Bundle id: `com.escandon.inkwell`. No third-party Swift dependencies; the only vendored asset is `mermaid.min.js`.

## Features

- Document-based (`DocumentGroup` + `FileDocument`), opens `.md`/`.markdown`/`.txt` from Finder, Files, and iCloud Drive.
- Live WYSIWYG styling over raw Markdown: headings, bold, italic, strikethrough, inline code, fenced code blocks, blockquotes, lists, links. Syntax markers show on the caret line and shrink/dim elsewhere.
- Source mode (plain monospace) and HTML preview (built-in converter, `WKWebView`).
- **Tables and mermaid diagrams render inline in the editor**, Typora-style. A GFM pipe table (alignment row, `\|` escapes, pipes inside code spans) is drawn as a grid and a ```` ```mermaid ```` fence as a diagram whenever the caret is outside the block; click into it (or arrow into it) and the source reappears for editing. The document text is never changed: the block's source is hidden with attributes and the first line is given the rendered height, and `NoteMarkerLayoutManager` paints over it (see `BlockRenderer`). Diagrams are rasterized by an offscreen `WKWebView` (`MermaidRenderer`) running the vendored runtime; the preview and exported HTML use the same runtime (`Inkwell/Resources/mermaid.min.js`, pinned to `MarkdownHTML.mermaidVersion`), inlined for the preview and referenced from the jsDelivr CDN in exports, so an exported file needs a network connection to draw diagrams.
- The entitlement `com.apple.security.network.client` is required: without it the sandboxed app's WebKit processes never start, so neither the preview window nor inline diagrams render, even for local HTML.
- Sidebar folder tree (security-scoped bookmark persists across launches); collapses on compact iPad widths.
- Outline panel with click-to-jump, word/character/reading-time status bar.
- Typewriter mode, focus mode, light/dark/sepia themes, adjustable font size.
- Export HTML, copy as HTML, insert table of contents.
- AI menu stub (disabled) with an `AIProvider` protocol ready for a Claude-backed implementation.
- **Notes / Questions**: anchor a question to any paragraph (⇧⌘N), see a colored dot in the margin, edit and resolve notes in the inspector's Notes tab, review every open question across documents in the Questions inbox, and export notes as inline HTML comments or a task list.

## Notes / Questions

Notes are stored outside the markdown file so documents stay byte-faithful. Each note records a question, optional answer, status (open / answered / dropped), tags, and an anchor: a security-scoped bookmark of the file, the nearest enclosing heading path, an ~80-character snippet of the selected/caret paragraph, and a character offset hint.

**Anchor resolution** (runs on open and after every edit, so dots follow their paragraphs): exact snippet match → case/diacritic-insensitive match on the first 30 characters → heading path → offset (accepted only if that paragraph still shares a word with the snippet). Notes that fail every step are listed as *Orphaned* and skipped by inline export (they go under an `<!-- orphaned notes -->` trailer instead).

**Where things are**

| UI | Location |
|---|---|
| Add Note… | Notes menu / toolbar bubble, ⇧⌘N. Enter saves. Requires a saved file (the anchor needs a bookmark). |
| Margin dot | Orange = open, green = answered, gray = dropped. Click it, or right-click / long-press the paragraph → **Show Notes**, to filter the panel to that paragraph. |
| Notes panel | Inspector (right sidebar) → Notes tab, ⌥⌘N. Status filter, inline question/answer/tag editing, status menu, jump, delete, and a disabled **Answer with AI** button. |
| Questions inbox | macOS: Window > Questions (⇧⌘Q). iPad: toolbar question-bubble button (full screen). Grouped by document, filtered by status and tag, searchable. Clicking a note resolves the bookmark, opens the document, and jumps to the anchor. |

**Data location**: SwiftData store at `~/Library/Containers/com.escandon.inkwell/Data/Library/Application Support/Inkwell/Notes.store` on macOS (the app's Application Support directory on iPadOS). Local only: CloudKit sync needs an iCloud container entitlement the project does not carry, so it was not enabled.

**Export formats**

- *Notes > Export Notes to Markdown…* — a copy of the current document (the original is untouched) with one HTML comment inserted on its own line after each anchored paragraph: `<!-- note[open] (2026-09-29): question — answer -->`.
- *Notes > Export All Questions…* (also from the inbox toolbar) — one markdown file, a `##` section per document, task-list items `- [ ] question (file › heading › path)`; answered/dropped notes are `[x]`, with answer and tags as sub-bullets.

**AI hook**: `AIProvider.answer(question:context:)` receives the question and the anchored paragraph with ~600 characters of context either side. `NoopAIProvider` throws `AIError.notConfigured`, so the button stays disabled until a real provider is installed.

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Bold / Italic / Inline code | ⌘B / ⌘I / ⌘E |
| Strikethrough | ⇧⌘X |
| Link | ⌘K |
| Heading 1–6 / Paragraph | ⇧⌘1…6 / ⇧⌘0 |
| Insert table of contents | ⇧⌘T |
| Source mode toggle | ⌘/ |
| HTML preview | ⇧⌘P |
| Export HTML | ⇧⌘E |
| Copy as HTML | ⌥⇧⌘C |
| Typewriter / Focus / Outline | ⌥⌘T / ⌥⌘F / ⌥⌘O |
| Add Note… / Show Notes | ⇧⌘N / ⌥⌘N |
| Questions window (macOS) | ⇧⌘Q |
| Bigger / smaller text | ⌘+ / ⌘− |

On iPad the same shortcuts work with a hardware keyboard (hold ⌘ to see the menu overlay).

## Architecture

```
Inkwell/
  App/        InkwellApp.swift (DocumentGroup + menu commands), Info.plist, entitlements
  Models/     MarkdownDocument (FileDocument + export docs), EditorSettings (UserDefaults-backed @Observable), Theme,
              Note (SwiftData model + NoteStatus)
  Markdown/   MarkdownStyler (attribute overlay), MarkdownHTML (md→HTML), MarkdownAnalysis (outline/stats/TOC)
  Editor/     MarkdownEditor (NSTextView/UITextView wrapper + EditorCore incremental restyle),
              EditorController (commands → text view, note anchors/markers), PlatformTypes (AppKit/UIKit shims),
              NoteMarkerLayoutManager (margin dots; InkwellTextView adds click + context menu on macOS)
  Views/      ContentView (NavigationSplitView + inspector tabs), Sidebar, Outline, NotesPanel, AddNoteSheet,
              QuestionsInbox, StatusBar, HTMLPreview, Settings, About
  Services/   AIService (AIProvider protocol + NoopAIProvider), FolderBookmarkStore,
              NoteStore (SwiftData container, bookmarks, NoteNavigator, NoteExport), NoteAnchorResolver
```

Design decisions:

- **Raw text is the model.** The document holds a `String`; the styler only sets attributes on the `NSTextStorage`, so files round-trip byte-for-byte and undo works natively.
- **Incremental restyle.** Each edit restyles only the affected paragraphs plus the previous/current caret paragraphs. A full pass runs only when a fence marker (```) is inserted or removed, because fences change block state below them.
- **Markers shrink rather than hide.** Keeping every character in layout means model offsets and hit-testing stay 1:1 with the text.
- **TextKit 1 on both platforms** for predictable attribute behavior across AppKit and UIKit.
- **MVVM-light.** `EditorController` is the per-document view model; app menus reach it through `@FocusedValue`. `EditorSettings` is a single observable so the native text view can read it without a SwiftUI environment.
- **AI seam.** `AIService.provider` is the only injection point; the menu enables itself when a provider reports `isAvailable`.
- **Note markers live in the layout manager, not the text.** The styler calls `setAttributes` on each restyle (which would erase a custom attribute), and a text attachment would shift character offsets. `NoteMarkerLayoutManager.drawBackground` paints dots from a plain `[NoteMarker]` array, identically under AppKit and UIKit TextKit 1.
- **Notes are matched to files by standardized path, opened by bookmark.** The path is the grouping key; the security-scoped bookmark is what the inbox resolves to reopen a file after relaunch.

## Adding a Claude provider later

Implement `AIProvider` in `Services/` (e.g. `ClaudeAIProvider`), return `isAvailable = true`, and set `AIService.provider` to it. Wire the four menu actions in `AICommands` to call the protocol methods with `AIRequestContext(document:selection:)`.

## Known limitations

- The Markdown→HTML converter covers common syntax, not full CommonMark (no tables, footnotes, or reference links).
- Live styling is per-paragraph; multi-line constructs other than fenced code (e.g. setext headings, lazy blockquote continuation) are not recognized.
- Typewriter scrolling is approximate on iPad while the software keyboard is up.
- Notes cannot be added to an unsaved (untitled) document; the anchor needs a file bookmark.
- If a file is moved outside the sandbox's reach, its notes appear in the inbox but opening reports a bookmark error.
- Notes sync is local only (no CloudKit); see Notes / Questions above.
