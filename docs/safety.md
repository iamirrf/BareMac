# How BareMac stays safe

BareMac makes seven promises. This page explains each one, the code that keeps it,
and the tests that prove it. If you find a way to break any of them, please report it
privately (see [SECURITY.md](../SECURITY.md)).

| # | Promise | Kept by | Proven by |
|---|---------|---------|-----------|
| 1 | **Trash only.** Nothing is ever permanently deleted, and BareMac never empties the Trash. | `FileEngine` uses `FileManager.trashItem(at:resultingItemURL:)` and nothing else. There is no delete function anywhere. | `SafetyContractTests.noDeletion`, `noEmptyTrash`, `onlyEngineMoves`; `Scripts/audit.sh` checks the built app for delete calls. |
| 2 | **Zero network.** No analytics, no update checks, no license checks — not one connection. | No networking API is used anywhere. Web links (About, Help) open in your browser. | `SafetyContractTests.noNetwork`; `Scripts/audit.sh` checks linked frameworks and symbols of the shipped binary. |
| 3 | **No privileges.** No helper tool, no `sudo`, nothing outside your own files. | The allowlist only accepts paths inside your home folder and app bundles *you* own. | `SafetyContractTests.noPrivileges`; `SafetyPolicyTests.appBundles` (an app owned by another user is refused). |
| 4 | **Measured bytes only.** Every size is measured from the files themselves. | `DiskMeasurer` walks with `fts(3)` and adds up allocated blocks (`st_blocks × 512`), counting hard links once and never following symbolic links. Items that can't be fully read are shown as information only. | `DiskMeasurerTests` compare against Foundation's independent count, check hard links, symlinks, unreadable folders and APFS clones. |
| 5 | **Preview before action.** Nothing moves until you've seen the exact list and confirmed it. Every move is logged and can be undone. | `FileEngine.preview` measures again and returns the exact list; `execute` only accepts a preview it issued, once. Every move is appended to `~/Library/Application Support/BareMac/action-log.jsonl` and flushed to disk. `restore` moves items back and never overwrites. | `FileEngineTests.previewRequired`, `previewMovesNothing`, `cleanRunIsExact`, `cleanRunIsRestorable`, `restoreNeverOverwrites`, `realTrashRoundTrip`. |
| 6 | **Allowlist discipline.** Only well-known, safe places are ever offered. Anything uncertain is information only. | `SafetyPolicy` decides, for each kind of item, exactly which folders are allowed — checked at scan time, at preview time, and again right before the move. | `SafetyPolicyTests` (every category, symlink escapes, `..` paths, protected folders) and each scanner's tests ("every cleanable item passes the policy"). |
| 7 | **Honesty.** No "RAM booster", no fake optimization, no invented numbers. | BareMac has no feature that can't be done safely and truthfully. Removing language files from apps is shown but never offered, because it breaks app signatures. | Code review — and you can read every line. |

## The path of a file

1. **A scanner finds it.** Scanners only read. Each found item goes through
   `ItemBuilder`, which measures it and asks `SafetyPolicy` whether its location is
   allowed for its kind. If not — or if any file inside couldn't be read — the item is
   shown with its size and the reason, but it can't be selected.
2. **You select it.** Suggestions are pre-selected only where removal is clearly safe
   (caches, logs, saved window positions). Anything that might hold your data starts
   unchecked.
3. **BareMac measures again and shows the exact list.** `FileEngine.preview` checks
   every item against the allowlist again, folds items that are inside other selected
   folders into them, refuses to take every copy of a duplicate, and measures each item
   fresh. The button says exactly how much will move, for example
   "Move 1.24 GB to Trash".
4. **You confirm.** Only then does `FileEngine.execute` run. It checks each item one
   last time (in case something changed, such as a folder replaced by a symbolic link),
   moves it to the Trash with macOS's own Trash function, and writes a log line with
   what moved, from where, to where in the Trash, when, and how many bytes.
5. **You can undo it.** History lists every action. "Put Back" moves an item from the
   Trash to exactly where it was, and refuses if something new is already there. You can
   also drag items back out of the Trash in Finder.

Moving to the Trash doesn't free space by itself. The space comes back when you empty
the Trash in Finder — which BareMac will never do for you.

## The allowlist, in plain words

BareMac only ever looks at moving items in these places:

| Kind | Allowed location | Notes |
|------|------------------|-------|
| Cache | Directly inside `~/Library/Caches` | Caches macOS manages for iCloud, Find My, background downloads and photo analysis are refused. |
| App cache | `~/Library/Containers/<app>/Data/Library/Caches/<item>` | Only with Full Disk Access; never Apple's containers. |
| Log | Directly inside `~/Library/Logs` | |
| Damaged setting | A `.plist` directly inside `~/Library/Preferences` that macOS can't read | |
| Device backup | A folder directly inside `~/Library/Application Support/MobileSync/Backup` | Never pre-selected. |
| Leftover | Directly inside one of 13 Library folders, named after an app ID | Never Apple's, never BareMac's own. |
| Uninstall file | The same Library folders, for the app you chose | Shared folders such as "Google" or "Microsoft" are refused. |
| App | `/Applications` or `~/Applications` (or one folder inside), owned by you | Never Apple's apps, never BareMac itself. Apps installed for all users must be moved in Finder. |
| Picked file | A regular file in your home folder | Not in `~/Library`, not hidden, not inside a package such as an app or photo library. |

Always off limits, whatever the kind: the Trash itself, your keychains, iCloud Drive,
Mail, Messages, Photos, `~/Library/Accounts`, macOS's privacy database, and BareMac's own
action log. Anything outside your home folder and the Applications folders is refused.

## Why some things are shown but never offered

- **Language files inside apps.** Removing them changes an app's signed contents, which
  can stop it from opening. BareMac shows how much space they use, and leaves them alone.
- **System logs.** macOS manages and rotates `/Library/Logs` and `/private/var/log`
  itself. They're outside your own files.
- **Files that might still be used.** If another installed app from the same developer
  could use a leftover, BareMac can't be sure, so it only shows it.
- **Anything it couldn't fully measure.** If macOS hides part of a folder, BareMac can't
  promise an exact size, so it won't offer to move it.

## Permissions BareMac may ask for

- **Full Disk Access** (optional). Lets BareMac *see* your Trash, device backups and App
  Store app caches. Without it, BareMac simply says what it can't see.
- **Desktop, Documents and Downloads** (macOS asks the first time Large & Old Files or
  Duplicates looks there). BareMac reads names, sizes and dates; Duplicates also reads
  contents to compare them. Nothing leaves your Mac.
- **App Management** (only when uninstalling). macOS asks before one app may move another.

BareMac never asks for your password, and it has no helper tool or background process.
