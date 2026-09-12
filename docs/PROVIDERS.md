# Provider Implementation Specifications

## Filesystem

Use asynchronous libuv filesystem operations. Enumerate immediate children only; paginate or batch processing of very wide directories. Avoid synchronous `stat` per entry when directory entry types are available. Unknown types use a bounded concurrency pool (initial maximum 16). Sort once per directory revision, not every render. Cache by lexical directory URI plus policy revision and filesystem invalidation generation.

Begin with explicit refresh and buffer-scoped save invalidation. Watchers are an optional later optimization: one lease per visible expanded directory, maximum 64 per workspace, released when no visible consumer exists. On watch failure or platform limitations, expose manual refresh and coalesced focus refresh; do not silently start whole-tree polling. Filesystem events mark caches dirty; they are hints, not a complete event log. See [libuv filesystem events](https://docs.libuv.org/en/v1.x/fs_event.html).

Policy has independent hidden, ignored and symlink settings. To obtain rg-consistent ignored-file filtering, use rg file enumeration on explicit workspace filtering, and a batched ignore adapter for directory views. WB-04 must prove parity using fixture `.gitignore`, `.ignore`, nested ignore rules and parent/global ignore settings before claiming identical scopes. Empty ignored directories require deliberate handling because file enumeration alone cannot describe them. Do not implement gitignore with a homemade glob parser.

Files outside a root can be opened but are marked external. Symlinks outside the root are shown, but following them is opt-in and bounded. Detect loops. Unreadable directories produce a retryable error row; disappearing files are removed with stable selection fallback. Preserve raw byte paths separately from escaped labels.

## MiniFiles Adapter Or Rewrite

The default plan is a new read-only tree renderer and filesystem provider. MiniFiles remains an optional public-API action for buffer-style filesystem editing. That adapter sets its target window through supported APIs and invalidates workbench caches after reported file actions; it does not share private state.

WB-03 is a bounded experiment against the installed and recorded upstream versions. Test persistent native split docking, two simultaneously expanded branches, focus return, terminal resizing and disposal. Passing requires public APIs only and no continual geometry repair hooks. Record results in an ADR evidence file. An inability to meet the public-API requirements is a successful negative experiment, not a reason to keep patching internals.

If a maintained fork is chosen later, specify exactly which upstream subsystem is reused, its pinned SHA, license notices, patch set, regression tests and update procedure. A fork that replaces layout, branch model and lifecycle is likely more expensive than the focused implementation. No runtime monkey-patches or `debug.getupvalue()` access. No upstream source is copied in this planning revision.

## Text Search

Use `vim.system(argv, opts, on_exit)` with streaming stdout, explicit cwd and bounded stderr. Build args as a list: `rg`, `--json`, `--line-number`, `--column`, appropriate case/ignore flags, `-e`, query, `--`, scope paths. `-e` ensures a query beginning with `-` is data. Disable external rg config through supported invocation/environment control so the UI's effective policy is authoritative; do not mutate global environment variables. rg guidance describes ignore behavior and explicit option control. [ripgrep guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md).

Parse newline-delimited JSON incrementally; chunks may split inside a JSON object or UTF-8 sequence. Preserve an incomplete tail. Decode `text` versus base64 `bytes`, including paths; offsets reference decoded bytes. Treat begin/end/context/match/summary explicitly. Do not split human-readable `path:line:text`. [JSON printer protocol](https://github.com/BurntSushi/ripgrep/blob/master/crates/printer/src/json.rs).

Exit 0 with no failures is complete; exit 1 is normal no-match; other exits are errors with bounded stderr. Cancellation and budget termination are different from process errors. Cap parser tail and payload bytes; a gigantic line must produce truncation/unsupported status, not unbounded allocation. Consume batches on the main loop under the CPU slice budget. On backpressure cap, terminate the producer and mark partial, rather than accumulating an unlimited queue.

Empty search does not spawn. Default debounce 80 ms, configurable 30-300 ms. One active search per session and at most two process requests per workspace initially. Cancel superseded work immediately. Old result callbacks must be rejected after scheduling as well as before it. Search history stores structured options and resource scope, not a serialized shell command.

Fzf remains an optional quick-pick frontend for files/actions. Its adapter receives explicit cwd and serializes opaque item IDs alongside sanitized labels. Do not make terminal output the authoritative result model. Fzf-lua exposes per-call options and picker customization, so global plugin setup need not be overwritten. [Fzf-lua options](https://github.com/ibhagwan/fzf-lua/blob/main/OPTIONS.md).

## LSP Discovery

Use attached native clients and public request/cancel APIs; workbench does not start or configure servers. Probe method support per buffer at execution time. Requests capture client ID, buffer ID, workspace generation and document changedtick. Use a fixed initial capability cache and invalidate on attach/detach; dynamically registered capabilities must be rechecked on execution. Never override global handlers just to collect workbench output. [Neovim LSP API](https://neovim.io/doc/user/lsp/).

| Feature | Protocol operation | Normalization and limits |
|---|---|---|
| Outline | `textDocument/documentSymbol` | Handle nested DocumentSymbol and flat SymbolInformation; preserve ranges and selection ranges |
| Workspace symbols | `workspace/symbol`, optional `workspaceSymbol/resolve` | Retain original client and resolve data; debounce query; cap results |
| Definition/type/implementation | Relevant textDocument method | Handle Location, LocationLink, arrays, null; preserve target selection range |
| References | `textDocument/references` | Explicit includeDeclaration; dedupe by URI/range/encoding after safe normalization |
| Calls | prepareCallHierarchy, incomingCalls/outgoingCalls | Original client/item data; lazy edges; multiple roots and cycles |
| Code actions | textDocument/codeAction and optional resolve | Native apply/execute semantics; availability is not a completed edit |

Normalize each client's results separately before merging. Do not combine UTF-8 and UTF-16 columns as equal integers. Navigation converts against actual target text; unloaded targets must not be loaded merely to populate a list. If exact cross-encoding deduplication requires loading, retain both with provenance until inspected.

Call hierarchy is a prepared item followed by directional requests; preserve opaque server data. Default maximum expansion depth 8, 200 children per node and 2,000 edges per result set; show limit rows and explicit load-more where bounded. Incoming calls' `fromRanges` belong to the caller, outgoing ranges belong to the source item. Test these independently. [LSP call hierarchy specification](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/callHierarchy.md).

Do not promise Tree-sitter semantic references. A later local structural outline fallback can advertise that it is syntax-derived and depends on available parsers/queries. No parser installation or project indexing on opening a view. LSP timeouts mark partial/error per client so a slow server does not erase another client's results.

## Diagnostics

Consume native diagnostic state and scoped change notifications. Store buffer/URI and namespace provenance. Update only affected resources and increment/decrement ancestor aggregates, rather than repeatedly scanning all buffers per row. Removing diagnostics removes stale badges. Subscribe only while needed, with a shared lease when Files and Problems both display them. [DiagnosticChanged documentation](https://neovim.io/doc/user/diagnostic/).

Distinguish reported-only coverage from known workspace completeness. Native diagnostics may exist only for analyzed buffers; workbench must not eagerly open every file to obtain more. Workspace diagnostic pulling is a separately negotiated capability, not an assumption. Mixed language roots, detached clients, unnamed buffers and diagnostics outside the selected root require explicit filtering rules.

## Git

Use one asynchronous `git status --porcelain=v2 -z` per repository refresh, coalesced and cached. Parse record types and NUL-separated names structurally, including renames' second paths, unmerged records and untracked entries. Never split on whitespace. Treat Git worktree directory, Git metadata directory and workspace root as distinct identities. [Git status porcelain format](https://git-scm.com/docs/git-status).

Aggregate badges incrementally. Request diffs only for selected files; bound preview bytes. Non-Git directories retain all other capabilities. Watch-triggered refresh is debounced; each cursor move cannot spawn Git. Status and diff are read-only in the core release. Hunk staging, discard, commit and conflict resolution need separate operation specifications.

## Filesystem Operations

WB-21 adds explicit create, rename, move, copy and trash actions through an operation service. Use native filesystem calls or a structured trash adapter. Never simulate changes by rewriting display labels. Default delete is recoverable trash; if unavailable, disable that action with a reason and expose permanent delete only as a separately reviewed operation.

Preflight checks: source identity/version, destination existence, write permissions, dirty buffers, symlink behavior, case-only renames, directory self-descend, cross-device moves, and server file-operation capabilities. Cross-device moves require a verified copy then delete path and recovery record; unsupported cases fail before mutation. Serialize overlapping operations; no two plans may mutate the same subtree concurrently.

For LSP-aware rename, negotiate file-operation support and obtain applicable `workspace/willRenameFiles` edits before changing disk; preserve server filters and client encoding, apply compatible edits once, then report successful operations with the corresponding notification. Reject conflicting client edits for review. Neovim's workspace edit support can be used but does not imply transactional disk rollback. [LSP willRenameFiles](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/workspace/willRenameFiles.md).

Order is specified per operation plan and proven with injected failures. A failed filesystem step cannot emit success notifications. Renaming an open modified buffer must preserve text and undo or refuse with an actionable reason. Update URI indexes and invalidate views only after the actual successful step. Case-only rename may require a temporary intermediate path; never overwrite an unrelated target.

## Replacement And Persistence

WB-22 supports reviewed literal, single-line replacement first. Build edits against exact searched bytes or a captured dirty-buffer snapshot. Check preimages again at apply, apply in descending offset order per file, preserve encoding/EOL and file mode, and group undo per buffer. No runtime use of Lua patterns for ripgrep regex replacement. Regex/capture replacement needs an explicit engine-consistent design before becoming available.

For unloaded files use a sibling temporary file and rename where supported; preserve metadata deliberately and document cross-file non-atomicity. A recovery journal records preimages/affected paths under a bounded local state directory. Do not persist file contents beyond what the explicitly requested operation's recovery requires; define cleanup/expiry and allow disabling history. Never auto-apply a recovered operation after restart.

Session persistence stores schema version, root identities, view state and bounded query metadata. No raw window/buffer handles, running jobs, executable Lua or full search results by default. Restore lazily on explicit workspace activation; stale paths are marked unavailable. Use write-to-temp plus rename and a corruption fallback. Never write to the source repository or a Nix store path as ambient session persistence.
