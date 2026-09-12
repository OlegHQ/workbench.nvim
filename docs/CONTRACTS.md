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

Namespaces: `workspace.*`, `view.*`, `files.*`, `search.*`, `navigation.*`, `symbols.*`, `problems.*`, `settings.*`, `git.*`. Public registration rejects duplicate IDs; replacements are explicit and disposables restore only the registrations they own. Initially contribution registration accepts plain Lua records, not a separate manifest language or expression parser.

## Feature Lifecycle And Settings

```text
disabled -> enabling -> enabled -> disabling -> disabled
                 \-> error
error -> enabling (explicit retry)
```

Validate a candidate config before modifying active state. Each changed key has a declared owner, type/default, scope, apply mode (`live` or `restart-required`), getter and setter/disposer. `false` is a value, not absence; lists replace by default, maps merge by declared schema. Repeated enable/configure cannot duplicate hooks. If activation fails, dispose newly created effects, retain the prior valid effective settings where possible, and report the failed key. Do not pretend to provide arbitrary transactional rollback across unrelated external services.

Effective precedence: plugin defaults < user setup/TOML < explicitly loaded data-only workspace overrides < session < buffer where supported. Display requested and effective values, provenance, restart requirements and dependency state. Persisting is a separate explicit action; ordinary toggles affect the session. No automatic writes to Nix-generated read-only config. Runtime state is JSON under `stdpath('state')/workbench`, never executable Lua.

## Navigation Contract

`preview(location, session)` affects only workbench preview resources. `open(location, mode, origin)` resolves a valid editor target and commits a navigation step. Modes: current editor, vertical split, horizontal split, tab. `return_to_origin(session)` restores window, buffer and view where still valid. Fallback order is last valid editor window in that tab, another normal editor window, then a newly created editor split. A sidebar is never the fallback editing target.

Unmodified preview buffers owned by workbench can be reused/disposed. Existing user buffers, modified buffers, terminal buffers and user splits cannot be wiped. Preview reads bounded text without triggering an LSP client for every result. Opening commits to a normal buffer using native APIs. History stores locations and views, never assumes window IDs survive sessions. Preserve native jumplist behavior for committed jumps, and keep result traversal distinct from arbitrary cursor movements.

## Operations Contract

Filesystem changes and workspace replacement use a distinct `OperationPlan`: ID, immutable input snapshot, proposed steps, affected resources, preconditions, review diff, recovery information and state. States are draft, validated, reviewed, applying, applied, partial, failed, cancelled. A reviewed plan is invalidated by a changed target/preimage before apply.

No cross-file atomicity guarantee is claimed. Apply checks collisions and dirty buffers first; failures stop further dependent steps and produce a recovery ledger. UI renderers never issue filesystem changes. Supported operation types and limitations are specified in PROVIDERS.md; unimplemented types remain unavailable.
