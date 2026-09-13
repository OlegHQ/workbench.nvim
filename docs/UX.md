# Workbench UX Specification

## Primary Journey

Open a repository, expand two unrelated branches, select a folder and search inside it. Inspect several matches without leaving the result list, open one in the editor, inspect references, return to the original file, and reopen the original search at the same selection. Every step must have a discoverable action, a stable origin, and a visible scope.

WB-11 must demonstrate this journey through text search. WB-17 extends it through semantic references. A tree screenshot alone cannot satisfy either gate.

## Surfaces

| Surface | Default role | Retained state |
|---|---|---|
| Sidebar | Switch between Files, Outline, Problems; later Git and Buffers | Per-view selection, expansion and scroll per tab/workspace |
| Results panel | Grouped search/reference/call results | Query, flags, scope, selected ID and group expansion |
| Preview | Read-only bounded context beside/below the active view | Current preview target; no editing history |
| Action palette | Search actions and settings with effective shortcuts/state | Recent actions, bounded history |
| Editor | Normal Neovim editing | Neovim owns buffers, undo and normal window layout |

Only one sidebar container per tab initially. Switching view mounts its saved session without resetting the other sessions. Results default to a bottom split. Each view can be closed, focused or toggled independently. A global hide action closes workbench surfaces and restores the editor. No startup dashboard.

Within a public sidebar, `]v` and `[v` cycle forward and backward through the current contextual `sidebar.views` order. Switching focuses the destination sidebar and leaves Search open. These buffer-local mappings are owned by the mounted view and removed when it closes.

Use native split windows for persistent UI. Sidebar target width 32 cells, user-adjustable 24-48; reserve at least 60 editor columns and 8 editor rows. Below the minimum, collapse the persistent sidebar into an explicitly opened overlay, or show results without preview. Test 160x50, 120x35, 80x24 and 60x20 terminal grids. Clamp dimensions on resize. Never obscure a prompt or leave an unusably narrow editor.

## Interaction Rules

| Intent | View behavior |
|---|---|
| Move up/down | `j/k` and arrow keys move selection; no committed jump |
| Expand/descend | `l` or Right expands; on file previews or opens according to explicit action |
| Collapse/parent | `h` or Left collapses an expanded node, otherwise selects parent |
| Open | Enter opens in editor and focuses editor; directories toggle expansion |
| Preview | Explicit preview action keeps focus in source view |
| Split/tab | Named actions with visible effective mappings |
| Filter | `/` in a tree opens its filter input; search view owns its query field |
| Escape | Cancel transient input first; otherwise return focus to origin without destroying retained results |
| Close | `q` closes the active workbench view and releases live resources |
| Help | `?` shows actions available in the current view and item context |

Exact global mappings are selected in integration, after checking existing keys. Preserve `Space f`, `Space /`, `Space o/O`, `Space d`, `gd/gr/gy/gi` until explicit migration. Do not reserve a new multi-key leader namespace until autoconf's parser supports it; the current parser discards intermediate nesting.

Mouse click selects; double-click opens; expander click toggles; wheel scrolls without changing the active editor. Keyboard alone must reach every action. ASCII labels and fallback icons work without a patched font. Badge meaning cannot depend on color alone. Escape control characters in filenames and crop by display cells, not bytes; keep raw paths in item payloads.

## Files

The sidebar shows independent expanded branches, directories before files, deterministic sorting, and a clearly labeled root. Expansion loads only that directory. A loading row is immediately visible if enumeration is pending. Reveal expands ancestors and selects the file without resetting unrelated branches or changing cwd. A missing/outside-root file offers a root action, not silent root switching.

Filtering searches known nodes first, then optionally runs a bounded asynchronous file enumeration to find paths. Show whether results are local-to-loaded-tree or workspace-wide. Preserve ancestors of matches and save the prefilter expansion state. Clearing a filter restores that state. Hidden and ignored toggles show their current state and apply through the shared policy service; `.git` internals stay excluded by default.

Context actions: open modes, reveal, copy absolute/relative path, search in folder, refresh, toggle hidden/ignored. Create/rename/move/copy/trash are added only when WB-21 passes. There is no fake editable-buffer mode in the read-only release.

## Search

Search input displays query and scope: workspace, selected folder, current file, or open buffers. Literal search is the default; regex, case-sensitive/smart-case, whole-word, include/exclude and hidden/ignored settings are visible controls/actions. Search regex dialect is ripgrep's default engine. PCRE2 is an optional explicit capability, not assumed.

Debounce input, cancel superseded requests, stream groups by file, and allow navigation while results arrive. Typing a new query cannot flash old results as current. Empty query performs no repository scan. Invalid regex, permission errors, missing rg, no matches, cancellation and truncation have distinct states. Existing results can remain visible with a stale/previous-query label while a new query starts.

Search disk contents initially and label that fact when relevant buffers are modified. An open-buffer search is a distinct capability; WB-18 adds dirty-buffer overlays with the same matcher semantics before claiming unified unsaved-content search. Never silently mix Vim regex with ripgrep regex. Result summaries count received results and indicate caps or errors.

Retain the last 10 result sets subject to the memory budget; pinning prevents ordinary LRU eviction but never bypasses the cap. On cap pressure, ask which set to replace or refuse the new pin with a reason. Resume restores query/flags/scope/selection; rerun is explicit and retains the same investigation identity with a new generation. Export to quickfix creates a workbench-owned list entry; do not mutate another plugin's list.

Replacement initially supports literal single-line search/replacement with selected matches and a diff review. Regex captures, multiline and PCRE2 replacement remain unavailable until matching/expansion semantics and tests exist. Apply is separate from review. Changes since review invalidate affected steps; partial apply has a recovery report. Global undo is not advertised without a tested journal.

## Code Discovery

Outline follows the last active real editor buffer, not the sidebar buffer. It shows nested symbols where the server supplies hierarchy, supports filter and source-order/name-order, and highlights the enclosing symbol without stealing selection during manual browsing. Breadcrumbs are optional and use the same symbol snapshot; they do not make independent LSP requests.

Workspace symbols offer debounced search and support resolving a selected incomplete symbol through its original client. References and implementations populate the same results panel with location previews and return behavior. Call hierarchy expands incoming or outgoing edges on demand with a visible direction selector, cycle markers and depth/result caps. No project-wide eager call graph.

Capability state is buffer/client aware. An unattached server, unsupported method, server error and zero results cannot all render as an empty list. Multiple clients retain provenance and deterministic deduplication. Hover/code actions may use native UI initially; the palette exposes availability without starting providers just to draw itself.

## Problems, Git And Working Set

Problems groups reported diagnostics by workspace root and file, filters severity/source, preserves selection across updates and opens locations through navigation. The title must say reported problems when workspace coverage is unknown. No claim that every unopened file is clean.

Git initially shows read-only status and diff previews. Distinguish staged, unstaged, untracked and conflict states. Repository identity matters for worktrees and submodules. Staging/discard/commit are deferred separately; a file status badge is not authorization to add destructive Git commands.

Buffers view lists real open buffers with modified/read-only markers, recent ordering and explicit close/save actions. Closing a modified buffer uses Neovim's normal preservation behavior. A hidden buffer is not a closed file; visible editor splits remain user-owned.

## Settings And Recovery

Settings show effective value, scope and source. Toggle actions update live state or explain a restart requirement. Disabled optional providers release listeners/jobs; reopening them does not silently re-enable the setting. Persist only through an explicit save action, with a writable target and preimage check. In a Nix deployment, show the owning configuration file and allow a session override.

Health reports actual binaries, active clients/methods, settings, retained handles and last error. Notifications are reserved for user-requested actions that fail; background refresh failures appear in their view with retry. No silent `pcall` returns that make a key appear broken.

## Acceptance Walkthroughs

| ID | Scenario | Required outcome |
|---|---|---|
| UX-01 | Expand A and B, open file in A, return | Both branches and cursor positions survive |
| UX-02 | Search folder A while editor cwd is B | Only A searched; cwd unchanged |
| UX-03 | Rapidly type three queries; first finishes last | Only latest generation affects current results |
| UX-04 | Preview 100 matches with one modified editor buffer | No user buffer wiped/changed; no preview jump history |
| UX-05 | Open result, inspect references, return, resume search | Original origin and selected match restored |
| UX-06 | Close tab during pending search/LSP response | No stale window writes or retained handles |
| UX-07 | Disable/re-enable feature three times | One instance of each owned hook; sibling feature survives |
| UX-08 | Missing rg or unsupported call hierarchy | Discoverable action with precise reason and recovery |
| UX-09 | Resize to narrow terminal, use keyboard and mouse | No overlap, invalid geometry or focus trap |
| UX-10 | Change file after reviewing replacement/rename | Apply refuses stale affected steps; no silent overwrite |
| UX-11 | Switch between two workspace tabs | Scope and selection remain isolated |
| UX-12 | Restart with corrupt saved state | Editor starts; only workbench state reset/recovered |
