# Shared Contracts

This is the normative design contract for WB-01 onward. Signatures are planned, not implemented. If a spike requires a change, revise the relevant ADR, this document, its callers, and tests together before dependent tasks proceed.

## Resource And Location

```lua
---@class WorkbenchResource
---@field uri string                 -- identity; never a display label
---@field scheme string              -- file, or explicitly supported virtual scheme
---@field path? string               -- absolute native path for file resources
---@field workspace_id? string
---@field display_path string        -- escaped for terminal display only

---@class WorkbenchLocation
---@field resource WorkbenchResource
---@field range? table               -- {start={line,character}, finish={line,character}}
---@field encoding? string           -- utf-8, utf-16, utf-32; mandatory with range
---@field version? integer           -- document version/changedtick when applicable
---@field client_id? integer         -- original LSP client when applicable
```

Ranges use zero-based lines and end-exclusive columns; encoding is explicit. A resource alone can be opened before its text is loaded. rg emits byte columns, represented as `utf-8`; LSP results retain the client's encoding until navigation resolves against actual buffer text. Never silently treat UTF-16 units as bytes. Cursor API conversion happens at the final navigation boundary. Reject malformed/out-of-bounds locations with an actionable stale result state, or clamp only where a documented preview fallback is safe.

Use Neovim URI helpers and native path helpers, not hand-built `file://` strings. Preserve case and original path bytes. Do not lowercase IDs on a case-sensitive filesystem. For existing roots, canonicalize once and retain a display alias; child symlink identity stays lexical so two entries are not accidentally collapsed. Symlink traversal is a separate policy; detect ancestor cycles using canonical identities only when following. A prefix is not containment: `/repo2` is not inside `/repo`.

Search, LSP, quickfix and UI each have an adapter for their indexing rules. Tests cover emoji before a match, combining characters, CJK, tabs, CRLF, URI escapes, colon/newline filenames, non-UTF-8 rg payloads, missing files, and non-file URIs. Unsupported virtual resources get a capability reason; do not pass their URI to a filesystem operation.

## Workspace Snapshot

```lua
---@class WorkbenchWorkspace
---@field id string
---@field generation integer
---@field roots WorkbenchResource[]
---@field active_root_uri string
---@field root_origin string         -- explicit, git, marker, cwd
---@field scope table                -- all roots or selected folder; explicit, not ambient cwd
---@field policy table               -- hidden, ignored, symlinks, include/exclude
```

Initial supported product: one root per workspace, multiple workspaces across tabpages. Store an ordered roots array now to avoid conflating root identity with a single pathname. Full multi-root execution is a later task, not silently emulated by searching the current directory. LSP workspace roots are inputs to capability routing, not automatic replacements for the user's chosen workspace.

Root selection precedence: explicit root; nearest Git worktree root for the initial real file; configured marker ancestor; launch cwd. For an empty launch, cwd is the root. Root detection occurs on workspace creation or explicit change, with cache invalidation on explicit refresh. Submodules remain separate Git repositories; selecting their folder as a search scope does not implicitly change the workspace. Never `:cd`/`:tcd` as a side effect of preview, reveal, or search.

## Items, Trees And Results

```lua
---@class WorkbenchItem
---@field id string                  -- stable inside result set, not row number
---@field kind string                -- file, directory, match, symbol, diagnostic, call
---@field label string
---@field location? WorkbenchLocation
---@field parent_id? string
---@field detail? string
---@field badges? table
---@field payload? table             -- typed by provider; never parsed from label

---@class WorkbenchResultSet
---@field id string
---@field provider_id string
---@field workspace_id string
---@field generation integer
---@field revision integer
---@field status string              -- idle/running/complete/partial/cancelled/error
---@field completeness string        -- complete/reported-only/truncated/unknown
---@field items table<string, WorkbenchItem>
---@field order string[]
---@field error? table
---@field query? table               -- structured query including scope and flags
```

A view session owns selected ID, expanded IDs, filter, scroll anchor, origin and result-set ID. ResultStore owns result data. Streaming merges update by ID and preserve selection; removing a selected item selects its next sibling, previous sibling, then parent. A result cannot become `complete` after cancellation. Empty complete and unavailable/error are separate states.

Filesystem IDs derive from parent/root plus lexical URI. Match IDs include resource URI, position and occurrence identity for a query generation. Symbol IDs are stable within one document revision; across revisions reconcile by provider identity or qualified name/kind/nearest range without claiming stability when ambiguous. Call rows use edge/path IDs and retain the underlying symbol separately. Cycle markers are non-expandable rows.

Do not globally resort all streamed items on each batch. Keep deterministic per-group ordering, insert/merge bounded batches and schedule one render per tick. A final sort may occur only within the measured budget and must preserve the selected ID. Loading/error/empty rows are view state, not fake navigable resources.

## Diagnostics Lease

The native diagnostics provider snapshots only existing named buffers and reports coverage as `reported-only` with completeness `unknown`; it never opens files or clears editor diagnostics. A `DiagnosticChanged` notification refreshes that buffer's complete current diagnostic set, including sibling namespaces, and updates only that resource. Removing its last diagnostic removes the stale report. The shared listener group exists only while at least one Problems or Files lease is active; releasing the last lease removes provider listeners but preserves Neovim-owned diagnostics. Reports retain resource URI/path and namespace identity/name for source filtering and badge aggregation.

The WB-08 implementation is constructed explicitly with `require("workbench.services.results").new(opts)`. `store:create(spec)` begins an `idle` or `running` set, `merge(id, dense_items)` updates by stable ID while retaining first-insertion order, `remove_items(id, ids)` applies selection fallback, and `finish(id, status, completeness, error)` closes the stream. Those mutation methods return small defensive summaries/deltas, not copies of the entire result set. Use `store:item(id, item_id)` or `store:page(id, offset, limit)` for bounded defensive reads; `get(id)`/`snapshot(id)` is the explicit full immutable snapshot used by export adapters. A streamed batch larger than `max_batch_items`, or an item/byte cap overflow, becomes visibly `partial`/`truncated`; it is never silently dropped and then called complete. Defaults bound each set to 10,000 items/8 MiB, the aggregate result payload to 32 MiB, each batch to 512 items, each item to 256 KiB, history to 16 sets, and view sessions to 16. Query metadata, filters, expansion IDs and anchors have separate count/byte caps. Options can lower or raise these limits explicitly.

`store:open_session(result_set_id, opts)` returns a lightweight view session with `select`, `preview`, filter/expanded/scroll-anchor setters, `snapshot`, `close` and `dispose`. Closing preserves bounded session state; `store:resume(session_id)` restores it. Selection reconciliation uses next sibling, previous sibling, then parent, retaining the current stable ID across ordinary streamed updates. Sets referenced by retained sessions cannot be evicted; when every slot is referenced, creating another set fails with a capacity reason until a session is disposed. Cancellation/error/partial are terminal states and cannot accept late batches or become complete.

## Provider Interface

```lua
provider:capabilities(context) --> { state, reason?, operations = {...} }
provider:start(request, sink)  --> request_handle
request_handle:cancel()        -- idempotent
request_handle:dispose()       -- cancel and release owned handles

sink({ kind = 'batch', generation = n, items = items })
sink({ kind = 'status', generation = n, status = 'partial', completeness = 'truncated' })
sink({ kind = 'done', generation = n, completeness = 'complete' })
sink({ kind = 'error', generation = n, error = { code = code, message = message } })
```

Request includes workspace snapshot, domain arguments, scope, generation and relevant buffer version. Provider methods cannot rely on `bufnr=0` or window 0 after asynchronous work begins. Capture concrete IDs. `sink` is application-owned, nonblocking, and rejects disposed or stale generations. No emissions are accepted after terminal completion; error may preserve previously received items with `partial` status and error details.

Each provider declares max retained items/bytes, concurrent requests, cancellation semantics and dependency checks. Overflow produces a visible truncated result, not silent loss. Processes are spawned with argument arrays, explicit cwd, bounded stderr and no shell evaluation. Request cancellation initiates termination and invalidates results immediately; process exit is cleaned up asynchronously.

## Actions And Capabilities

```lua
---@class WorkbenchAction
---@field id string                  -- e.g. search.in_folder
---@field title string
---@field category string
---@field scope string               -- global/workspace/buffer/view/item
---@field available fun(ctx): table  -- {enabled=boolean, reason?=string}
---@field checked? fun(ctx): boolean -- real effective value
---@field run fun(ctx,args): any
---@field args_schema? table

actions:register(action) --> disposable
actions:execute(id, context, args) --> { ok, value?, error? }
actions:list(context) --> metadata_projection
```

One registry powers the palette, help, keymaps and contextual actions. Availability functions read cached facts only and never start a server, process or scan. Execution rechecks availability, validates arguments and reports failures. Missing dependencies stay discoverable with reasons. User overrides take precedence over default mappings; collision detection reports both owners. Menus and help show the actual effective binding.

`args_schema` is a plain Lua table, not an expression language. The initial validator supports `object` properties/required/`additional_properties`, `array` items, `string`, `boolean`, `number`, `integer`, scalar `enum`, `min_length`/`max_length`, and numeric `minimum`/`maximum`. Registrations return idempotent disposables. Replacing an ID is explicit; disposing the replacement restores the previous registration only while that prior owner remains live. `list(context)` returns metadata and effective availability/checked values, never executable handlers.

Namespaces: `workspace.*`, `view.*`, `files.*`, `search.*`, `navigation.*`, `symbols.*`, `calls.*`, `problems.*`, `settings.*`, `git.*`. Call-hierarchy actions remain distinct from symbol/reference actions because their edge/path identities and lazy lifecycle differ. Public registration rejects duplicate IDs; replacements are explicit and disposables restore only the registrations they own. Initially contribution registration accepts plain Lua records, not a separate manifest language or expression parser.

## Owned Scopes

`Scope.new(name)` creates a lifetime owner. `scope:child(name)` creates nested ownership; `scope:defer(disposer, label, kind)` registers one cleanup; `scope:own(resource, disposer, label, kind)` owns a resource; `scope:schedule(callback, scheduler?)` guards queued work; and `scope:inventory()` returns live owned-resource labels and pending callbacks. `dispose()` marks dead first, cancels pending callback tickets, invokes remaining disposers in reverse registration order, continues after errors, and is idempotent. A late `defer()` runs its disposer immediately and returns a `scope_disposed` error. Scheduled work rechecks liveness/generation when delivered.

## Feature Lifecycle And Settings

```text
disabled -> enabling -> enabled -> disabling -> disabled
                 \-> error
error -> enabling (explicit retry)
```

Validate a candidate config before modifying active state. Each changed key has a declared owner, type/default, scope, apply mode (`live` or `restart-required`), getter and setter/disposer. `false` is a value, not absence; lists replace by default, maps merge by declared schema. Repeated enable/configure cannot duplicate hooks. If activation fails, dispose newly created effects, retain the prior valid effective settings where possible, and report the failed key. Do not pretend to provide arbitrary transactional rollback across unrelated external services.

Effective precedence: plugin defaults < user setup/TOML < explicitly loaded data-only workspace overrides < session < buffer where supported. Display requested and effective values, provenance, restart requirements and dependency state. Persisting is a separate explicit action; ordinary toggles affect the session. No automatic writes to Nix-generated read-only config. Runtime state is JSON under `stdpath('state')/workbench`, never executable Lua.

The composition root owns the settings store's injected `apply` callback. Validated configuration changes, snapshot restoration and override creation/disposal apply to the active runtime before reporting success. Failure restores the prior layer/override ownership and reapplies it; `setting_apply_failed` includes a separate `rollback_error` when recovery also fails. Recursive mutations during application return `settings_busy`. Settings disposal releases the callback. Runtime view contexts use the workspace ID and `tostring(tabpage_handle)` as the session ID, plus the originating real buffer where buffer overrides are supported.

Sidebar width and position apply to existing windows while preserving their view buffers, selection and editor focus; a hidden tab adopts its contextual geometry on the existing TabEnter reflow. Preview disable closes owned windows and invalidates pending reads; re-enable previews the existing selection without rerunning its search. `navigation:preview(location, session_id, callback, { max_output_bytes = n })` optionally lowers that request's output cap without changing another session's limits. Callers omitting the final argument retain the existing limits.

Search reads contextual debounce and result limits for each query. Changing a result limit cancels the active generation and reruns its query; changing debounce replaces a pending timer but does not rerun settled results. Provider requests and result-set creation accept optional positive integer `max_items`, bounded by their service ceiling; omission retains the existing default. Each result set captures its own cap, so settings changes cannot mutate retained history or sibling sessions. Aggregate disk/buffer overflow terminates all owned lanes as visibly truncated rather than attempting additional merges into a terminal set.

`workbench.services.persistence.new(opts)` constructs a dormant session store; construction and `workbench.setup()` do not scan or create state directories. `save(snapshot)`, `list()`, `restore(id)` and `delete(id)` are explicit operations. Records use schema 1 and an allowlisted data-only shape: workspace roots, active view, relative selection/expansion paths, bounded search query/flags/scope and a relative selected location. Window/buffer handles, callbacks, jobs, result IDs and complete result payloads are discarded. Each Neovim process writes only its unique `session-<id>.json` file using a same-directory verified temporary plus atomic rename; it never overwrites another session's file. Limits are 32 records, 4 MiB total and 256 KiB per record. A full history refuses new saves until an explicitly selected record is deleted. Corrupt/future schemas are reported and preserved. Schema 0 has a bounded one-root/query migration. Restore is data-only: roots are marked unavailable if missing, every retained query has stale results and requires an explicit rerun, and no workspace, provider, process or operation is activated automatically. The public API is `list_sessions()`, `save_session(snapshot)`, `restore_session(id)` and `delete_session(id)` after explicit `setup()`; these calls do not open UI or activate saved state.

`session.persist` gates explicit public saves using the current tab's session override. False returns `persistence_disabled` before constructing the service or writing state; true does not automatically save or restore anything. Reading and deleting existing records remain available while saving is disabled. Standalone persistence services remain explicitly invoked, independently of application settings. Public save callers must opt in with `session.persist = true`.

Files follow-active-file is view-owned and reads its contextual setting on application. Enabling reveals the originating editor file; subsequent real editor buffer/window entries reveal within the retained workspace without moving focus or selecting another root. Disable removes owned listeners and invalidates their pending selection continuation. Reveals also check captured view identity, workspace generation and a monotonically increasing reveal generation before delayed selection; a newer reveal or close rejects the older continuation.

When enabled from a real editor window, follow uses that current window; the original editor is only a fallback when invoked from a tool/preview. Reveal preserves lexical in-root paths. An outside-looking path is accepted only if one canonical-path lookup resolves inside the selected root, supporting workspace aliases without changing the root or parsing escaped display labels. Repeated editor paths are deduplicated before resolution.

Runtime visibility settings rebuild the retained tab policy only when its effective values change, then invalidate Files and rerun the active Search generation. Closed Search investigations receive the new snapshot and reconcile generation on reopen. Hidden/ignored UI toggles retain only their changed fields as workspace policy overrides, synchronize all tabs sharing that workspace, and do not mask unrelated configured fields. Include/exclude controls use the same bounded, validated update path. Search capability caching retains one generation/policy record per workspace instead of accumulating every generation. Following symlinks still reports the provider's explicit unsupported capability; toggling that setting back restores normal search without a restart.

`session.max_results_history` bounds each Search investigation, including closed views, to 1..16 retained entries. Reducing it preserves the current entry and releases the oldest other session handles. Increasing it does not resurrect discarded entries. At the store's shared hard ceiling, a new query releases an old reference from its own investigation before allocating; it never evicts another investigation's referenced results.

The public host command is `:Workbench [status|enable|disable|files|outline|problems|search|close]`; no argument remains a read-only status query. Loading or invoking it does not enable Workbench unless the user explicitly chooses `enable`. `setup({ enabled = false })` keeps execution disabled; an absent `enabled` preserves the current setting on repeated setup, while explicit `false` disables it. Before setup, status reports `disabled/not_setup`; opening a view while disabled returns a structured error and never enables it implicitly.

The public facade constructs its runtime on the first enabled `open()`. `open()` accepts the built-in `files`, `outline`, `problems` and `search` IDs and declared options (root, explicit workspace/scope, query, focus). Outline/LSP and Problems/diagnostics components are constructed only on their first requested open, under dedicated runtime child scopes. Sidebar opens enforce contextual `sidebar.views`; successful opens close the prior sidebar without closing Search. Removing a mounted view from configuration closes it; an invalid empty list is rejected without changing the active view. Disabling disposes those runtime resources and closes owned views; it must preserve modified user buffers and unrelated windows. Standalone setup remains disabled by default. Problems may browse workspace reports from an unnamed real editor origin; navigation still uses the shared modified-buffer protections.

Public sidebar cycle mappings read contextual view order on each invocation and belong to the mounted view scope. The runtime registers the lightweight Problems open action before loading its provider/controller, enforcing the same enabled-view and exclusive-sidebar rules as public commands. Runtime-owned controllers suppress their own duplicate open registration; standalone controller consumers retain their direct registration/open path. Disposing the runtime removes its action, and re-enabling creates a fresh registration on first runtime use.

Files and Problems retain selection, expansion and scroll offset in their existing data sessions when the mounted view closes. A new view accepts that offset and reconciles it against current rows and available height; it retains no prior native window/buffer handle. Problems releases its diagnostic lease on close while preserving expansion state separately from the disposed view.

Layout mount failures dispose only provisional view resources. Early editor-target, hook or child-scope failures may release an empty tab scope, but must not dispose a tab scope that still owns sibling views. Existing sibling buffers/windows remain usable and a subsequent mount can retry.

`Layout:mount({id=..., replace=true, ...})` stages a replacement while the prior view remains alive. Placement failure restores the original registration before disposing provisional resources, then restores focus, including when the old view is the tab's only view. Successful placement disposes the prior view. Search restores its active investigation pointer on failure. Files stages a new root-scoped session; Outline stages a new tab session when workspace identity changes; Problems retains its old data session and lease until replacement succeeds, then disposes them. The public runtime commits workspace identity only after the requested view opens successfully.

Disabled-view admission uses the candidate workspace context before workspace commitment. Rejection preserves retained tab snapshots, service generations/cache/active identity and mounted views. Requested sidebar controller construction also precedes commitment; failed constructors dispose their provisional provider scope and preserve existing views. The optional synchronous workspace-service admission predicate receives a defensive candidate snapshot and returns acceptance or an error; existing callers need no migration.

Outline retains up to 16 data-only view-state records keyed by tab, workspace and file: filter, order, breadcrumb preference, selection ID, expansion map and scroll offset. Closing still releases sessions, requests, watchers and observers. Reopening obtains fresh symbols before restoring selection/expansion/scroll through normal projection reconciliation; closing again while awaiting symbols preserves the pending saved selection. Switching to an uncached file starts with default preferences. Runtime TabClosed cleanup forgets that tab's records, and controller disposal clears all records. This is separate from symbol-result caching and does not keep provider execution alive.

Each tab retains its selected workspace across view close/reopen and cwd changes. Root detection uses the current real editor file before other editor windows only when the tab has no selected workspace. Explicit root changes invalidate the old Search request/view and update Files; root options must identify a directory. Runtime status exposes defensive per-tab `workspaces` snapshots. TabClosed schedules reference cleanup after Neovim invalidates the tab handle; a shared root is removed from the workspace cache only after its last tab releases it. Disable removes the lifecycle hook and all retained tab snapshots.

## Navigation Contract

`preview(location, session)` affects only workbench preview resources. `open(location, mode, origin)` resolves a valid editor target and commits a navigation step. Modes: current editor, vertical split, horizontal split, tab. `return_to_origin(session)` restores window, buffer and view where still valid. Fallback order is last valid editor window in that tab, another normal editor window, then a newly created editor split. A sidebar is never the fallback editing target.

Unmodified preview buffers owned by workbench can be reused/disposed. Existing user buffers, modified buffers, terminal buffers and user splits cannot be wiped. Preview reads bounded text without triggering an LSP client for every result. Opening commits to a normal buffer using native APIs. History stores locations and views, never assumes window IDs survive sessions. Preserve native jumplist behavior for committed jumps, and keep result traversal distinct from arbitrary cursor movements.

The WB-08 navigation service is injected with `require("workbench.services.navigation").new(opts)`. `navigation:preview(location, session_id, callback)` returns an idempotently cancellable request; a newer preview for the same session invalidates the older callback. At most eight preview reads can be pending. Loaded buffers, including unsaved changes, are read in place; otherwise a bounded libuv read collects only the requested line context. Preview has line, byte and scan caps and never creates a file buffer or editor jump. `navigation:open(location, mode, origin, session_id)` validates encoded ranges before changing a window, returns a structured receipt and records one native jump for a committed location. Navigation history is bounded to 16 session keys and 32 outstanding commits per session; capacity failures are structured and do not mutate windows. An unsaved origin cannot be replaced in `current` mode; use a split/tab. `return_to_origin(session_id)` restores a still-valid origin or uses a non-destructive editor-window fallback. `dispose()` cancels pending reads and rejects late callbacks.

Quickfix export is opt-in: `require("workbench.adapters.quickfix").export(result_snapshot, { title = ... })` appends one immutable snapshot after the current quickfix history, stores result-set/revision/item identity in list context/user data, skips unlocated and non-file items, and never opens the quickfix window. UTF-8 byte columns map directly to quickfix columns; UTF-16/UTF-32 columns are omitted rather than misrepresented.

## Operations Contract

Filesystem changes and workspace replacement use a distinct `OperationPlan`: ID, immutable input snapshot, proposed steps, affected resources, preconditions, review diff, recovery information and state. States are draft, validated, reviewed, applying, applied, partial, failed, cancelled. A reviewed plan is invalidated by a changed target/preimage before apply.

No cross-file atomicity guarantee is claimed. Apply checks collisions and dirty buffers first; failures stop further dependent steps and produce a recovery ledger. UI renderers never issue filesystem changes. Supported operation types and limitations are specified in PROVIDERS.md; unimplemented types remain unavailable.
