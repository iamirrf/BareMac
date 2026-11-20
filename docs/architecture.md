# Architecture

BareMac is a Swift Package with two targets and one test target.

```
Sources/
  BareMacCore/            the library: no UI imports, fully unit-tested
    Engine/               FileEngine (the only code that moves files) and ActionLog
    Safety/               SafetyPolicy — the allowlist
    Measure/              DiskMeasurer (fts walker), PrivateSize (APFS clones), UserFileWalk
    Models/               FoundItem, CleanCategory, ItemBuilder, ScanProgress
    Scanners/             one scanner per module, plus AppInventory and LibraryZone
    Support/              paths, app IDs (bundle identifiers), treemap layout
    System/               running apps, permissions, disk capacity, launchctl wrapper
  BareMac/                the SwiftUI app
    App/                  app entry point, menus, the Module list
    Model/                AppModel, one store per module, ScanTask, CleanCoordinator
    Views/                screens and shared components (Liquid Glass helpers)
    Support/              formatting, Finder/Settings helpers, the only web links
Tests/BareMacCoreTests/   fixture-based tests for every scanner, the engine and the contract
Scripts/                  build-app.sh, make-dmg.sh, notarize.sh, audit.sh
website/                  the static marketing site
```

## Rules the structure enforces

- **Scanners only read.** They return `FoundItem`s built by `ItemBuilder`, which measures
  each item and marks it information-only unless `SafetyPolicy` allows its location and
  every file inside was readable.
- **Only `FileEngine` moves files**, and only to the Trash (or back out of it). A source
  test fails the build if `trashItem`, `moveItem` or any delete call appears anywhere else.
- **Nothing moves without a preview.** `FileEngine.preview` returns a `CleanPreview` with
  freshly measured sizes; `execute` accepts only that preview's ID, once.
- **Every move is logged** to a plain JSON Lines file before `execute` returns.
- **No networking code exists**, and a source test keeps it that way.

## Data flow in the app

1. `AppModel.start()` measures the disk, checks Full Disk Access, lists running apps and
   installed apps (`AppInventory`), then runs the quick scans: System Junk, App Leftovers,
   Trash and Startup Items. Large & Old Files, Duplicates and Space Map scan on request.
2. Each module has a store (`SystemJunkStore`, `DuplicatesStore`, …) that owns a
   `ScanTask` and the set of checked items. `ScanTask` runs the scanner off the main
   thread, publishes real progress, and keeps the last result on screen during a rescan.
3. The Move to Trash button calls `AppModel.requestClean`, which hands a `CleanRequest` to
   `CleanCoordinator`. It asks the engine for a preview, shows `ConfirmSheet`, and on
   confirmation executes, then rescans and reloads History.
4. Undo and Put Back call `FileEngine.restore` with the logged records.

## Concurrency

Swift 6 language mode with strict concurrency. Scanners are `Sendable` structs whose
entry points are `@concurrent async`, so they always run off the main actor and check
for cancellation as they walk. UI state lives in `@MainActor @Observable` classes.
`FileEngine` is an actor, so moves never overlap.

## Liquid Glass

On macOS 26 and later the app uses the system's Liquid Glass (`glassEffect`,
`GlassEffectContainer` for the morphing Move to Trash bar, `.glass` and `.glassProminent`
buttons, `backgroundExtensionEffect` under the sidebar). On macOS 14 and 15 the same
views fall back to materials with a soft specular rim. With Reduce Transparency on, every
glass surface becomes a solid, high-contrast panel; with Reduce Motion on, illustrations
stop floating and transitions are removed. All of this lives in `Views/Components/Glass.swift`.
