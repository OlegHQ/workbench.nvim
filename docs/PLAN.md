# Workbench Implementation Plan

## Execution Entry

This plan is the implementation handoff. Runtime feature work starts after WB-01 establishes local validation. Read [AGENTS.md](../AGENTS.md), [ARCHITECTURE.md](ARCHITECTURE.md), [CONTRACTS.md](CONTRACTS.md) and [VALIDATION.md](VALIDATION.md), then select a ready task from [tasks.json](tasks.json).

```sh
python3 scripts/check_plan.py
python3 scripts/check_plan.py --next
```

The manifest is authoritative for dependencies, required gates, task status and milestone membership. The task descriptions below are authoritative for behavior and implementation scope. Update both together when scope changes. An agent must never treat `todo`, `in_progress`, `blocked` or `deferred` as completed. `done` requires evidence and completed dependencies.

The user's requested milestone bounds execution. A request to implement the next task does not imply implementing every deferred feature. An agent can complete prerequisites within a requested milestone without asking again. Keep one active task by default; broader concurrent ownership is only used when explicitly authorized.

All validation runs locally. Do not add GitHub Actions or other hosted CI. Runtime acceptance requires local Neovim end-to-end tests, not just unit tests or direct controller calls.

The completed implementation audit is recorded in [CORE-REVIEW.md](evidence/CORE-REVIEW.md). It supplements historical task records with current-checkout failure, lifecycle, real-provider, UI, compatibility and performance evidence for WB-01 through WB-24.

## Document Map

| Need | Document |
|---|---|
| Evidence and alternatives | [RESEARCH.md](RESEARCH.md) |
| Why a design was selected | [DECISIONS.md](DECISIONS.md) |
| Dependency direction and state owners | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Precise interfaces and lifecycle | [CONTRACTS.md](CONTRACTS.md) |
| Interaction and acceptance journeys | [UX.md](UX.md) |
| Domain implementation details | [PROVIDERS.md](PROVIDERS.md) |
| TOML, existing plugin repairs, Nix and release | [INTEGRATION.md](INTEGRATION.md) |
| Evidence, tests and measurable budgets | [VALIDATION.md](VALIDATION.md) |

## Milestones

| Milestone | Product outcome | Completion |
|---|---|---|
| Foundation | Tested models, ownership and explorer decision | WB-01..WB-06 |
| Exploration | Files -> scoped search -> preview -> open -> return -> resume | WB-01..WB-11 |
| Discovery | Outline, workspace symbols, references, calls and Problems | Exploration plus WB-12..WB-17 |
| Core workbench | Dirty-buffer search, settings, Git, reviewed operations, persistence | WB-01..WB-24 |
| Follow-on | Multi-root, tasks, tests/debug, remote/structural capabilities | Separate promoted tasks WB-27..WB-30 |

Do not implement a wide API shell before a usable journey. Build Files with the minimum projection it needs; use Outline to validate reuse. Stop extending an abstraction when it no longer reduces real duplication. Correctness and lifetime paths ship with each feature, not in a final cleanup sprint.

## Task Specifications

### WB-01

**Local Neovim test harness, environment inventory and baseline.** Owner: workbench. Read VALIDATION and ADR-008/010. Create `tests/runtime/`, `tests/e2e/`, `bench/`, a minimal Neovim test init and development dependency pinning. Provide the six local runtime commands specified in VALIDATION, including `make test-e2e`, fail nonzero on errors, and implement an initial literal import-boundary guard. The end-to-end driver must launch real isolated Neovim processes, attach a UI grid, drive commands/key/mouse input, inspect rendered output and focus, and collect local artifacts. Prove the driver detects deliberately wrong rendering/focus and cleans up failed child processes. Record installed optional plugin provenance and verify public APIs on the selected minimum Neovim patch and current host. No hosted CI setup belongs to this task.

Generate deterministic normal/stress fixtures outside the repo's tracked files. Measure startup and first-use baselines of the current host and an isolated plugin-free baseline. Intentionally break a test and import boundary in a temporary fixture to prove gates reject failures. Do not use historical 92/134 ms claims as fresh data. Done when the harness, fixture metadata and baseline evidence are reproducible; no runtime feature is implied.

### WB-02

**Repair existing editor feature ownership.** Owner: autoconf. Depends on WB-01. Follow INTEGRATION's repair list in the autoconf repository: actual completion controls, one save-format hook, scoped cleanup, LSP capability timing and reversible configured-server toggles. Add focused tests there; use the workbench evidence record to link its tested commit.

Verify normal-mode edit/write before InsertEnter, repeated configuration, auto-format false, unrelated save-hook survival, completion false/true and client setup before completion UI. Check actual installed Blink/Conform APIs. Keep host defaults unchanged unless correcting a documented broken behavior. Done when effective settings correspond to observed behavior and startup/first-input regressions are measured.

### WB-03

**Explorer feasibility experiment and decision.** Owner: workbench. Depends on WB-01. Read explorer research and PROVIDERS. Build isolated temporary experiments for public MiniFiles docking and a minimal native split projection; optionally compare Neo-tree/Snacks if installed or available in an isolated development environment. Do not add comparison plugins to the user's runtime.

Test two branches, editor focus, resize, reopen selection and cleanup; inspect exact upstream/installed versions. Record public/private API boundaries and timing under identical fixtures. Update ADR-003 with a chosen approach and explicit rejected alternatives. A documented inability to dock MiniFiles through supported APIs closes the experiment; endless private patching does not. No production fork without provenance/update plan.

### WB-04

**Resource, location and workspace model.** Owner: workbench core/services. Depends on WB-01. Implement CONTRACTS resource/location/workspace types and root policy as concrete modules with tests. Add injected root/ignore services and prove containment, aliases, nested repos, cwd independence and single-root capability limits. Keep LSP encoding unconverted until target text is available. Establish shared file/search policy fixtures; until WB-07/WB-09 adapters exist and prove parity, their filtering behavior remains unavailable rather than independently inferred.

Test UTF-16/UTF-8 coordinates, escaped URI paths, symlink cycles and root generation changes. Establish shared file/search policy test fixtures; document unresolved adapter limitations as unavailable behavior rather than silently inconsistent scope. Done when two independent consumers can obtain the same explicit workspace snapshot without reading ambient cwd.

### WB-05

**Scopes, action registry and lazy composition.** Owner: workbench core. Depends on WB-04. Implement disposable scopes, action metadata/availability and a minimal explicit composition root. Add a cheap public command entrypoint only after its dormant overhead is measured. Expose setup/execute/status with the planned contract; commands do not implicitly enable disabled features.

Test disposer errors, double disposal, late resource registration, duplicate action IDs, stale scheduled callbacks, unavailable action reasons and no heavy providers loaded at startup. A synthetic capability must register/unregister without changing another capability. Done when resource inventories and effective state can be inspected through tests/health, with no generic global bus.

### WB-06

**Layout, view lifecycle and reusable projection.** Owner: workbench UI. Depends on WB-03/WB-05. Implement native sidebar/results splits, view mount/unmount, buffer-local mappings and a simple tree/list projection over stable IDs. Introduce only the rendering primitives needed by Files. Preserve editor windows, normal buffer ownership and return targets.

Exercise all terminal grid sizes, theme links, empty/loading/error rows, display-cell truncation, mouse selection and keyboard help. Close a tab while render work is queued; resize during preview. Done when geometry/focus remain valid and 100 open-close cycles show no owned leaks. Providers are synthetic here; a renderer may not spawn filesystem work.

### WB-07

**Read-only Files sidebar.** Owner: workbench filesystem/explorer. Depends on WB-04/WB-06. Implement immediate-directory asynchronous enumeration, bounded caches, branch expansion, stable filtering, reveal and context actions through a Files controller. Support independent branches and preserve state across editor visits. Use explicit refresh initially; defer optional watchers unless required by measured UX.

Test inaccessible/vanished directories, 20k siblings, raw path display, hidden/ignored policy, external symlinks, filter clear restoration and root changes. No filesystem mutation shortcuts. Done when UX-01/02/09/11 relevant parts pass and directory cost is proportional to visited data, not repository size.

### WB-08

**Results, preview and navigation continuity.** Owner: workbench results/navigation. Depends on WB-06. Implement ResultStore, view sessions, bounded history and preview/open/return. Add explicit quickfix snapshot export through a public adapter. Preview uses bounded reads or existing buffers without opening every result as a live LSP document.

Test modified buffers, vanished origin window, split/tab opens, closed targets, preview churn, stable streamed selection and native jumplist compatibility. A committed open records an origin exactly once; preview records none. Done when synthetic results demonstrate selection -> preview -> open -> back -> resume without damaging user state or unrelated quickfix history.

### WB-09

**Structured asynchronous rg provider.** Owner: workbench search provider. Depends on WB-04/WB-05/WB-08. Implement argv construction, explicit scope/policy, streaming JSON parser, bounded batches and cancellation. Include error/status mapping and raw-byte payload support. Do not call a shell or parse colored path:line output.

Run real rg fixtures and injected chunk-boundary cases. Verify invalid regex, leading dash queries, no matches, non-UTF-8 payloads, enormous lines, stderr limits and late completion after cancellation. Done when the provider works without any UI and produces deterministic typed results within memory/CPU budgets.

### WB-10

**Persistent search interface and discovery palette.** Owner: workbench search/controller UI. Depends on WB-07/WB-08/WB-09. Compose visible query/scope/flags, grouped results, debounce, preview, resume/rerun and search-in-folder. Add an action palette and context help from the registry; optionally adapt installed Fzf for quick pick through public per-call options.

Verify every state in UX Search, including disk-vs-unsaved warning, cancellation and truncation. Typing must remain responsive while matches stream. No hidden/ignored toggle may disagree with provider args. Done when the loop works through actual rg and native windows, not a mocked results panel.

### WB-11

**Exploration acceptance checkpoint.** Owner: workbench integration. Depends on WB-02/WB-07/WB-08/WB-10. Run UX-01..04 and UX-06..09/11 on real fixtures; exercise the search -> preview -> open -> return -> resume portion of UX-05. Review public API boundaries and compare startup/first-use budgets.

Fix failures before adding semantic features. Record a concise terminal walkthrough and resource/performance evidence. Done means a usable exploration capability in an isolated runtime. It does not mean the Nix host default was enabled.

### WB-12

**LSP capability routing and normalization.** Owner: workbench LSP provider. Depends on WB-05/WB-08. Implement request/cancel and capability routing using attached native clients. Normalize locations/links/symbol forms, preserving client ID, encoding and buffer version. Build a fake server with controllable responses through the runtime harness.

Test mixed encodings, null/partial errors, detach mid-request, dynamic capability recheck and virtual URI rejection/fallback. Done when no UI is needed to assert correct normalized data and stale response rejection, and an actual configured server confirms adapter compatibility.

### WB-13

**Document outline and shared breadcrumbs.** Owner: workbench discovery/UI. Depends on WB-07/WB-12. Implement Outline using the same projection primitives as Files; keep its domain model separate. Add filter/order, last-real-buffer tracking and optional enclosing-symbol/breadcrumb projection from the same snapshot.

Test nested/flat symbols, repeated names, source edits while response pending, unavailable servers and manual selection while editor cursor moves. Done when tree reuse does not introduce filesystem assumptions or duplicate symbol requests. Syntax-derived fallback remains WB-30 unless separately promoted.

### WB-14

**Workspace symbols and reference navigation.** Owner: workbench discovery. Depends on WB-10/WB-12. Expose symbol search/resolve, references, definitions/type definitions and implementations through action registry and shared results/navigation. Explicit includeDeclaration flows from settings. Keep user mappings until host migration.

Test multiple clients, unresolved workspace symbols, outside-root targets and unchanged original search state while references are inspected. Done when UX-05 passes for a real language server and missing support is distinguishable from an empty result.

### WB-15

**Lazy call hierarchy.** Owner: workbench LSP/discovery. Depends on WB-13/WB-14. Implement prepare, incoming/outgoing selection and lazy edge expansion with client payload, cycle detection and depth/child caps. Preserve distinct edges to the same symbol. Use call locations appropriate to direction.

Test recursion, mutually recursive functions, multiple preparation roots, partial failures, switched direction and cancelled expansion. Done when navigation returns to the originating code and expanding a node never eagerly requests the whole graph.

### WB-16

**Workspace reported Problems and badges.** Owner: workbench diagnostics. Depends on WB-07/WB-12. Aggregate native diagnostics by URI/namespace, filter by source/severity/root and share leases between sidebar badges and Problems. Update changed resources incrementally.

Test diagnostic deletion, detached clients, unrelated root buffers, no diagnostics and known-incomplete coverage. Done when the view never implies every file was analyzed, and closing all consumers removes its listeners without clearing editor diagnostics.

### WB-17

**Discovery acceptance checkpoint.** Owner: workbench integration. Depends on WB-11/WB-13/WB-14/WB-15/WB-16. Run the complete UX-05 loop, two-client/encoding race tests and real-server checks in representative TypeScript, Python or Rust fixtures available in the host. Unsupported capabilities must be reported precisely.

Measure requests per interaction, UI responsiveness and idle resource counts. Done when semantic exploration uses one navigation/results model and hidden views trigger no refresh work. This checkpoint cannot be passed using only screenshots or fake-server tests.

### WB-18

**Working set and unsaved-content search.** Owner: workbench buffers/search. Depends on WB-10/WB-14. Add open-buffer/recent-buffer view and explicit open-buffer search. Design dirty-buffer overlays using the same rg matcher semantics against captured snapshots; merge by URI and supersede disk matches for included dirty buffers.

Test unnamed buffers, encoding/EOL, external disk changes, buffer edits after capture and mixed saved/unsaved results. No per-keystroke process per open buffer without a measured bound. Done when the UI accurately describes search scope and replacement can identify exact source snapshots; unsupported engine modes remain disabled.

### WB-19

**Effective settings and autoconf action integration.** Owner: workbench/autoconf. Depends on WB-02/WB-05/WB-10. Implement config schema, provenance, live session/buffer overrides and registered editor-setting adapters. Add validated TOML translation and resolve nested mapping limitation with tests or retain flat mappings. No silent catch-all passthrough.

Test false values, lists, unknown keys, failed activation rollback, read-only config and external host features absent in standalone workbench. Done when completion/formatting/diagnostic toggles show actual state and repeated toggles preserve sibling resources. Persisting user TOML is not required for live session controls; explicit save must show a real writable target or refuse accurately.

### WB-20

**Read-only Git source and diff preview.** Owner: workbench Git. Depends on WB-07/WB-08. Implement batched porcelain-v2 NUL parsing, repository cache, aggregates and selected-file diff preview. Distinguish worktrees/submodules and staged/unstaged/conflict/untracked states.

Test rename paths containing spaces/newlines, non-Git roots, rapid refresh and large diffs. Done when cursor motion does not spawn Git and closing all consumers releases refresh resources. Staging/discard/commit remain unavailable, not undocumented commands.

### WB-21

**Reviewed filesystem operation service.** Owner: workbench operations. Depends on WB-07/WB-12/WB-19. Implement operation plans and explicit create/rename/move/copy/trash actions per PROVIDERS. Include LSP-aware file-operation ordering and open-buffer preservation. Start with supported local cases and clear unsupported cross-device/cyclic behavior.

Inject collisions, stale sources, dirty buffers, case-only renames, permissions, symlinks, partial copy and conflicting LSP edits. Done only when G6 evidence proves failure recovery and no silent overwrite, and each action's review reflects the exact pending operation. This is not a bulk editable filesystem buffer rewrite.

### WB-22

**Reviewed literal workspace replacement.** Owner: workbench search/operations. Depends on WB-18/WB-21. Implement selected-match single-line literal replacement plans, diff review, preimage verification, per-buffer undo grouping, unloaded-file preservation and recovery journal. Do not expose regex replacement until engine-consistent capture expansion is separately specified.

Test overlapping/stale edits, CRLF, permissions, dirty buffer snapshots, partial multi-file failure and restart recovery metadata. Done when a reviewed plan cannot overwrite subsequently changed content and failures report exact applied/unapplied steps. No unsupported global-undo claim.

### WB-23

**Bounded workspace persistence and session recovery.** Owner: workbench persistence. Depends on WB-08/WB-19. Persist versioned data-only root/view/query state, restore lazily, and enforce count/byte caps. Exclude handles, executable state and full results by default. Specify two-process write behavior (session-specific files initially) to avoid last-writer corruption.

Test corrupt/version-mismatched JSON, missing roots, permission failures, two Neovim sessions, stale result metadata and old schema migration. Done when editor startup remains unaffected by corrupt workbench state and no search/process/operation runs automatically from saved data.

### WB-24

**Semantic theming and usability validation.** Owner: workbench/themekit. Depends on WB-06/WB-10. Add semantic default links and themekit mappings; test available light/dark themes, no icons, monochrome markers and all terminal grids. Theme switching must not restart providers.

Check truncation, keyboard reachability, mouse targets, focus contrast and loading/error states. Done when screenshots and focus assertions establish readable nonoverlapping UI in the actual Neovim grid. Keep RGB definitions in theme files, not workbench Lua.

## Removed Release Tasks

WB-25 (runtime packaging and rollout) and WB-26 (core release acceptance) were removed at the user's request on 2026-09-13. Core now consists of WB-01 through WB-24, with their existing behavior, lifecycle, UX, performance, compatibility and mutation gates intact. The host-rollout milestone is removed. Follow-on tasks depend directly on the retained core tasks and remain deferred.

Existing implementation and historical WB-25 evidence are retained for inspection; they do not prove publication or host activation. Publication, exact Nix pin/gitlink parity, fresh-install reproduction and host activation are outside this implementation review. The integration runbook remains applicable to any separately requested release. The current review covers the implemented core, real Neovim journeys and failure paths, including existing public runtime integration.

## Deferred Capability Specifications

### WB-27

**Multi-root execution.** Deferred until core is proven. Extend workspace scope routing across explicit roots, choose deterministic ordering and deduplication for nested/overlapping roots, label result provenance, cap aggregate concurrency and map LSP clients without reconfiguring them. Test two repos with identical relative paths, submodules, root removal and independent view sessions. Completion requires G0..G5 plus relevant host evidence. Do not merely change a single root field into an array; that model is already present.

### WB-28

**Terminals and task runner integration.** Deferred extension. Specify a task record with explicit command argv, cwd, environment, lifecycle and output locations. Use Neovim terminals for interactive processes; terminal state is not a result tree. Feed parsed task diagnostics into dedicated result ownership without replacing LSP diagnostics. Tasks start only through explicit actions, never by opening a project. Define stop/restart, exit status, output bounds, orphan cleanup and data-only workspace config before implementation. Gate with real subprocesses, cancellation and UI focus tests.

### WB-29

**Tests and debugging adapters.** Deferred extension. Evaluate existing test/DAP integrations through public APIs. Preserve test IDs/results and debug session/thread/frame models; share locations/actions/layout rather than inventing fake file nodes. Define one owner for breakpoints, process/session teardown, task output and panel leases. Prove unsupported adapters remain discoverable, disconnect does not kill unrelated processes, and returning from a frame restores the user's navigation context. No custom debug protocol engine unless evidence justifies it.

### WB-30

**Remote resources, syntax outline and advanced search.** Deferred design bundle that must be split into independently owned tasks before promotion. Research URI capability adapters for remote files; local path APIs must reject unsupported schemes. Evaluate Tree-sitter structural outline with explicit parser/query availability. Specify engine-consistent regex/multiline replacement and recovery before enabling it. These are distinct capabilities with different risk; they share existing boundaries but must not be implemented as one unreviewable feature commit.

## Handoff Procedure

After each completed task, leave its evidence and manifest status consistent, report affected repository SHAs/diffs, and identify the next ready task. If an implementation discovery changes scope, revise the ADR/contracts/dependencies before continuing. If a test environment is missing, finish independent work and record exactly which gate remains unverified. Do not manufacture success or repeatedly ask for permission already granted by the active implementation request.
