# Architecture Decisions

Accepted here means selected for implementation planning, not implemented or benchmarked. Every revision records its motivating evidence and affected task IDs in Git history. An agent can revise a decision with evidence; it cannot silently bypass it.

## ADR-001: Own The Workbench Interaction Layer

Status: accepted. Workbench owns views, shared workspace/results/navigation and action discovery. Neovim owns editing and LSP clients. Domain engines remain native/rg/Git. Reason: the audited UX gaps concern consistency and state. Consequence: providers and UI can be tested independently. Rejected default: rewrite completion, LSP transport, fuzzy matching and parsers alongside the sidebar. Those require separate demonstrated needs.

## ADR-002: Explicit Composition And Small Shared Contracts

Status: accepted. A single composition root injects services into controllers; providers and renderers do not import one another. Shared contracts cover identity, location, result, action and lifetime. Domain-specific payloads remain typed. Consequence: no global bus/container; adding Outline after Files validates actual reuse. Revision trigger: a concrete second implementation cannot fit without duplicated lifecycle/navigation behavior.

## ADR-003: Native Sidebar, Optional MiniFiles

Discovery metadata is distinct from provider activation. The runtime owns the Problems open action from its first construction so Search's action palette can discover it before the first Problems view. The controller/provider remain lazy; standalone controller users still receive the controller-owned action by default. Runtime construction explicitly suppresses that duplicate registration.

Status: accepted; WB-03 public-API feasibility experiment completed. Use native splits and a focused tree projection for persistent multi-branch navigation. Retain MiniFiles as an optional directory-edit action. Do not fork first. A fork would require evidence of reusable upstream internals behind a maintained public or deliberately extracted boundary, with lower maintenance cost and equal behavior/performance. A new renderer is not licensed as an upstream derivative unless code is actually copied; copied code requires provenance and notices.

WB-03 tested the installed Nix MiniFiles 0.18.0 package (`/nix/store/zcxj726i529m6gwr3dk1yp4jdnrvr163-vimplugin-mini.files-0.18.0`; installed `lua/mini/files.lua` SHA-256 `a68bdfe4ea2d158b823f8292ae022add9b2170d30a6eaf65c6d8b57d5bd1a80b`) on Neovim 0.11.7 and 0.12.4. Upstream [v0.18.0 release notes](https://github.com/nvim-mini/mini.nvim/releases/tag/v0.18.0) identify the `get_explorer_state()` and `set_branch()` APIs; the [MiniFiles help for that release](https://github.com/nvim-mini/mini.nvim/blob/v0.18.0/doc/mini-files.txt) specifies a single active branch and side-by-side floating windows. Local ext_linegrid inspection confirmed every opened explorer window has `relative = "editor"`. The public `set_target_window()` changes the destination for opening files, not the explorer's own layout.

On the same temporary fixture containing sibling `alpha/` and `beta/` branches, MiniFiles opened a file into its selected target and restored branch/cursor on reopen, but switching the branch removed the other sibling and opening a file kept focus in MiniFiles until close. Its windows resized within all four tested grids (160x50, 120x35, 80x24, 60x20) and close restored the editor window. The native split prototype kept both sibling rows visible, returned editor focus, retained selection across reopen, and disposed its projection buffer/window. At 80x24 and 60x20 a fixed 32-column sidebar left only 47 and 27 editor columns respectively; WB-06 must use the UX-specified compact/overlay fallback below the persistent-sidebar threshold.

Twenty warm open-to-first-frame cycles on current Neovim measured MiniFiles at p50/p95 5.261/6.134 ms and the minimal native split at 0.540/1.152 ms. These are not feature-equivalent measurements: MiniFiles enumerated and rendered actual fixture directories while the native experiment rendered a minimal two-branch projection. Minimum Neovim 0.11.7 also completed the four-grid focus/reopen/cleanup experiment (five cycles per layout). Neo-tree and Snacks were not installed and no comparison plugin was added. Full local results and screen captures: `.test-output/e2e/wb03-20260912T135307Z-750804/`; the experiment runner is `tests/experiments/wb03_explorer.py`.

## ADR-004: Typed Results Independent Of Pickers

Status: accepted. Search/LSP results live in ResultStore. Fzf is an optional selection adapter; quickfix export is explicit. Reason: resumability and stable selected IDs cannot depend on parsing a terminal display. Consequence: no global Fzf setup overwrite and no automatic replacement of unrelated quickfix lists.

## ADR-005: Request Generations And Disposable Scopes

Status: accepted. Every request checks workspace/document generation and scope liveness. Every external resource has a single disposer. Reason: cancellation does not prevent already queued callbacks. Consequence: tests include delayed replies after close/disable and repeated enable/disable. Do not introduce a promise library just for cancellation.

## ADR-006: Data-Only Settings With Effective State

The public runtime now connects the existing Outline and Problems controllers through lazily owned provider/controller pairs and enforces the configured sidebar view list. Public opens mount a replacement successfully before closing the old sidebar, preserving the old view on construction/mount failure. Search remains a separate results surface. This does not by itself prove per-view state retention; the core review tracks that requirement independently.

Visibility settings now update the runtime's retained snapshots instead of leaving existing views on construction-time policy. Files and Search receive the same snapshot. UI policy overrides are sparse, so changing hidden visibility does not freeze ignored visibility or other policy fields. Include/exclude controls validate before changing ownership state. Capability caches compare generation and policy and retain one record per workspace. Unsupported symlink traversal remains explicit rather than silently relaxing provider containment guarantees.

Session settings retain explicit persistence: `session.persist` permits public save operations, not automatic writes or execution on restore. Read/delete remain available with saving disabled. Public save callers now opt in explicitly; direct persistence-service callers retain their existing explicit API. Search history limits apply per investigation and preserve its current entry while pruning other references, including closed views. Service-wide capacity remains independently bounded.

Search settings use the same injected application boundary: debounce belongs to the active query timer and result caps belong to individual provider requests/result sets. Shared service ceilings stay fixed. The optional `max_items` request/create field preserves existing standalone callers and avoids changing sibling investigations when a contextual override changes. Search cancels superseded work and reports aggregate disk/buffer truncation through the normal terminal lifecycle.

Status: accepted. Autoconf translates TOML; workbench validates its own settings and exposes effective provenance. Session overrides are immediate; persistence is explicit. Completion/formatting remain autoconf-owned through registered setting adapters. Reason: present log-only switches and blanket cleanup are unreliable. No `setup()` success can substitute for observed feature behavior.

The runtime review found a missing application boundary: values changed while active views retained their old options. The composition root now injects one application callback into its settings owner. Configuration, snapshot restore and override registration/disposal invoke it after validation; failure restores the previous data and reapplies it, reporting a rollback error separately if necessary. Reentrant settings mutation is rejected. This is a single explicit dependency, not a subscription bus. Layout reads contextual sidebar options only when placing a view, and Preview captures a per-request output cap without mutating the shared navigation service's limits. Existing callers without an application callback remain valid standalone settings stores.

## ADR-007: Read-Only Exploration Before Mutations

Status: accepted. Explorer and Git start read-only. Filesystem changes and literal replacement are separate operation plans with preflight/review/recovery. Reason: navigation architecture can be delivered and validated independently of filesystem failure recovery. Consequence: missing mutation actions are labeled unavailable until their milestone, not supplied as shell shortcuts.

## ADR-008: Version And Dependency Baseline

Status: accepted and verified in WB-01. Minimum supported target is Neovim 0.11.7; test it alongside the current host 0.12.4. Use only released public APIs available on the minimum, or isolate optional newer behavior. Native split APIs may vary; layout adapter must test the minimum. No runtime dependency on a plugin manager, Python, Node, a test framework or GUI browser. rg is required only for rg search; missing rg leaves Files and actions usable. Fzf/MiniFiles are optional adapters. mini.test is pinned as a development-only harness dependency.

## ADR-009: Single-Root First With Explicit Multi-Root Model

Status: accepted. Workspace identity contains an ordered roots array; initial execution supports one root and multiple independent workspace tabs. Multi-root execution is a named follow-on task with its own duplicate/nested-root policy. Reason: the model can preserve identity without premature multi-root orchestration. No hidden cwd changes.

The public runtime retains the chosen workspace snapshot per tab handle. Omitted root options reuse that snapshot; an explicit change invalidates the old Search view before updating Files. A runtime-owned TabClosed callback releases closed-tab references after the event, preserving roots shared by live tabs. Root discovery runs only for an uninitialized tab or explicit selection. The callback is installed on first runtime construction and removed on disable/disposal; it performs no filesystem discovery.

Workspace service opens accept an optional synchronous admission predicate. The runtime uses the candidate's contextual settings to reject disabled sidebar views before committing workspace identity, generation, active selection or canonical-root cache entries. It also constructs the requested sidebar controller during admission; constructor errors dispose provisional providers without changing the selected workspace or closing existing views. Root resolution uses a small pending cache overlay, not a copy of all retained roots. Existing service callers omit the predicate and retain their behavior. Mounting failures after admission still require separate review.

Root changes use staged layout replacement: retain the old view until the destination is placed, then commit the runtime workspace. Search restores its active investigation on failure. Files, Outline and Problems stage replacement sessions under their existing controller scopes; successful replacement disposes root-specific old sessions and leases. This avoids reconstructing cancelled requests, results or diagnostic subscriptions during rollback.

## ADR-010: Measure Startup And Interaction Separately

Status: accepted. Host startup must satisfy its existing 150 ms target on the reference machine, with >10 ms regression investigation. Workbench also has idle/first-use/streaming/disposal budgets. Performance numbers in VALIDATION are targets until measured. All measurements and validations run locally, including end-to-end tests in real Neovim instances. No GitHub Actions or other hosted CI is part of this project.

## ADR-011: Planning-Only Repository First

Status: accepted. Publish this specification under OlegHQ/workbench.nvim on dev and register the native submodule in nvim-config. Do not add a runtime entrypoint or Nix installation input before a releasable capability exists. Reason: planning delivery should not change the editor. Runtime Nix wiring, exact pin verification and default capability rollout follow the integration runbook when a release is requested. WB-25 and WB-26 were removed from the core implementation scope by user request on 2026-09-13; existing per-feature gates remain required.

## ADR-012: Broad Workbench Scope, Staged Extensions

Status: accepted. Terminal/task/test/debug/multi-root/remote integrations are specified as follow-on capabilities, not prerequisites for the exploration release. They use actions, locations, results and scopes where appropriate, but retain native domain models. No fabricated graph node or file path represents a debug session or setting. Promotion from deferred requires its interface, UX and gates to be added before runtime work starts.
