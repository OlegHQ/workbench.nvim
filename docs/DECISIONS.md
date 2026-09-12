# Architecture Decisions

Accepted here means selected for implementation planning, not implemented or benchmarked. Every revision records its motivating evidence and affected task IDs in Git history. An agent can revise a decision with evidence; it cannot silently bypass it.

## ADR-001: Own The Workbench Interaction Layer

Status: accepted. Workbench owns views, shared workspace/results/navigation and action discovery. Neovim owns editing and LSP clients. Domain engines remain native/rg/Git. Reason: the audited UX gaps concern consistency and state. Consequence: providers and UI can be tested independently. Rejected default: rewrite completion, LSP transport, fuzzy matching and parsers alongside the sidebar. Those require separate demonstrated needs.

## ADR-002: Explicit Composition And Small Shared Contracts

Status: accepted. A single composition root injects services into controllers; providers and renderers do not import one another. Shared contracts cover identity, location, result, action and lifetime. Domain-specific payloads remain typed. Consequence: no global bus/container; adding Outline after Files validates actual reuse. Revision trigger: a concrete second implementation cannot fit without duplicated lifecycle/navigation behavior.

## ADR-003: Native Sidebar, Optional MiniFiles

Status: accepted direction, public-API feasibility experiment required in WB-03. Use native splits and a new tree projection for persistent multi-branch navigation. Retain MiniFiles as an optional directory-edit action. Evidence: RESEARCH explorer comparison and local floating geometry code. Do not fork first. Fork criterion: an experiment demonstrates reusable upstream internals behind a maintained public or deliberately extracted boundary, with lower maintenance cost and equal behavior/performance. A new renderer is not licensed as an upstream derivative unless code is actually copied; copied code requires provenance and notices.

## ADR-004: Typed Results Independent Of Pickers

Status: accepted. Search/LSP results live in ResultStore. Fzf is an optional selection adapter; quickfix export is explicit. Reason: resumability and stable selected IDs cannot depend on parsing a terminal display. Consequence: no global Fzf setup overwrite and no automatic replacement of unrelated quickfix lists.

## ADR-005: Request Generations And Disposable Scopes

Status: accepted. Every request checks workspace/document generation and scope liveness. Every external resource has a single disposer. Reason: cancellation does not prevent already queued callbacks. Consequence: tests include delayed replies after close/disable and repeated enable/disable. Do not introduce a promise library just for cancellation.

## ADR-006: Data-Only Settings With Effective State

Status: accepted. Autoconf translates TOML; workbench validates its own settings and exposes effective provenance. Session overrides are immediate; persistence is explicit. Completion/formatting remain autoconf-owned through registered setting adapters. Reason: present log-only switches and blanket cleanup are unreliable. No `setup()` success can substitute for observed feature behavior.

## ADR-007: Read-Only Exploration Before Mutations

Status: accepted. Explorer and Git start read-only. Filesystem changes and literal replacement are separate operation plans with preflight/review/recovery. Reason: navigation architecture can be delivered and validated independently of filesystem failure recovery. Consequence: missing mutation actions are labeled unavailable until their milestone, not supplied as shell shortcuts.

## ADR-008: Version And Dependency Baseline

Status: accepted target, verification required in WB-01. Target Neovim >=0.11 with explicit testing on the selected minimum stable patch and the current host 0.12.4. Use only released public APIs available on the minimum, or isolate optional newer behavior. Native split APIs may vary; layout adapter must test the minimum. No runtime dependency on a plugin manager, Python, Node, a test framework or GUI browser. rg is required only for rg search; missing rg leaves Files and actions usable. Fzf/MiniFiles are optional adapters. mini.test is a pinned development-only harness candidate.

## ADR-009: Single-Root First With Explicit Multi-Root Model

Status: accepted. Workspace identity contains an ordered roots array; initial execution supports one root and multiple independent workspace tabs. Multi-root execution is a named follow-on task with its own duplicate/nested-root policy. Reason: the model can preserve identity without premature multi-root orchestration. No hidden cwd changes.

## ADR-010: Measure Startup And Interaction Separately

Status: accepted. Host startup must satisfy its existing 150 ms target on the reference machine, with >10 ms regression investigation. Workbench also has idle/first-use/streaming/disposal budgets. Performance numbers in VALIDATION are targets until measured. CI checks ratios only under controlled conditions and cannot establish a reference-machine absolute result from a shared runner.

## ADR-011: Planning-Only Repository First

Status: accepted. Publish this specification under OlegHQ/workbench.nvim on dev and register the native submodule in nvim-config. Do not add a runtime entrypoint or Nix installation input before a releasable capability exists. Reason: planning delivery should not change the editor. WB-25 owns future runtime Nix wiring, exact pin verification and default capability rollout.

## ADR-012: Broad Workbench Scope, Staged Extensions

Status: accepted. Terminal/task/test/debug/multi-root/remote integrations are specified as follow-on capabilities, not prerequisites for the exploration release. They use actions, locations, results and scopes where appropriate, but retain native domain models. No fabricated graph node or file path represents a debug session or setting. Promotion from deferred requires its interface, UX and gates to be added before runtime work starts.
