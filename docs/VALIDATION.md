# Validation And Completion Gates

## Two Different Kinds Of Completion

Planning validation checks that tasks, dependencies, ownership labels, links and evidence references form a usable specification. It does not prove runtime architecture, performance, UI quality or successful release. `scripts/check_plan.py` is intentionally a structural validator. A human or implementing agent must inspect whether the evidence establishes the claimed behavior.

Runtime completion is per task and per milestone. A task cannot be done while a dependency is unfinished. Every required gate has a passing evidence record, commands or inspection procedure, and actual results. A screenshot proves appearance, not cancellation; a mock provider proves controller behavior, not rg compatibility. Use the appropriate combination.

## Gates

| ID | Gate | Evidence required |
|---|---|---|
| G0 | Scope and ownership | Changed paths/repositories; module owner; resource creation/disposal inventory; dependency direction review |
| G1 | Contract and behavior | Public contract assertions, success/failure cases, actual user outcome, integration tests where adapters exist |
| G2 | Lifetime and races | Repeated enable/disable/open/close; delayed callback after close; no leaked owned resources or sibling interference |
| G3 | UX and accessibility | Applicable UX walkthrough IDs, actual terminal grids, keyboard/mouse/focus, empty/error/loading/disabled states |
| G4 | Performance | Controlled before/after results, fixture/version metadata, startup and relevant interaction metrics |
| G5 | Compatibility and host | Minimum/current Neovim tests, optional dependency failure, standalone and autoconf integration, relevant theme/Nix tests |
| G6 | Mutation integrity | Preimage conflicts, dirty buffers, partial failure/recovery, encoding/EOL/permissions and LSP operation ordering |
| G7 | Publication and reproducibility | Published plugin/parent SHAs, gitlinks/pins, clean recursive clone and Nix build/activation evidence as applicable |

WB-01 creates executable runtime gates. Later tasks cannot rely only on this table. Gate requirements for each task are encoded in `docs/tasks.json`; changing requirements needs a documented reason and must not relabel an observed failure as success.

## Ownership Gate Implementation

WB-01 builds an import-boundary check for literal `require()` calls under `lua/workbench`. Core cannot import services/providers/UI; providers cannot import UI/controllers; UI cannot import providers/controllers; adapters use the public API; composition alone wires dependencies. Dynamic requires must be declared in an explicit allowlist and reviewed. A lexical check is a guardrail, not proof: injected objects and side effects require manual inspection plus tests.

The task manifest's `allowed_paths` are expected implementation paths relative to each named repository, not a substitute for the user's authorization. Task status/evidence/docs changes in workbench are implicit for every task. If a necessary implementation path is missing, record the concrete ownership reason and amend the manifest before editing it. This is routine design maintenance, not a new permission checkpoint. It cannot transfer a provider's UI ownership or bypass dependency gates.

Runtime instrumentation tracks resources owned by each scope: processes, timers, watchers, subscriptions, autocommands, buffers/windows and pending renders. Snapshots before/after each lifecycle test compare only owned resources, not global Neovim noise. Test that cleanup leaves a separately registered foreign autocmd and a modified user buffer intact.

Contract tests run Files and a synthetic second provider through the same controller/view boundary, then Outline supplies a real second consumer. A view must not acquire a provider dependency just to get its label. Ownership approval is recorded as a review conclusion, not inferred from a green import checker.

## Test Harness

WB-01 provides `make test`, `make test-integration`, `make test-ui`, `make bench` and `make check-ownership`. These are planned commands until WB-01 implements them. A missing command is not a passing gate. Use pinned mini.test in the development environment for child-Neovim control and screenshot assertions; do not add it to runtime dependencies. [mini.test](https://github.com/nvim-mini/mini.test).

Tests run isolated from personal configuration and use temporary fixtures. Unit tests exercise pure data transitions. Integration tests run real rg/filesystem/Git processes and a deterministic fake LSP server with encoded positions, partial responses and controllable latency. At least one host integration run uses actual configured language servers and installed optional plugins. Verify test runner exits nonzero on failure.

UI validation uses Neovim's real terminal/RPC grid, not a browser mockup. Capture text and highlight screenshots for the four grids in UX.md. Record mouse actions, focus IDs and editor buffer contents. Test terminal escape/control filenames without rendering active terminal control sequences. First release requires both macOS and Linux coverage, with unsupported environments reported separately.

## Performance Targets

These are initial engineering budgets, not achieved measurements. WB-01 calibrates fixture generation and records hardware/tool versions. Alter a target only with evidence and an ADR explaining the user impact; do not silently increase it to pass a regression.

| Metric | Initial target | Measurement |
|---|---|---|
| Full host startup | Under 150 ms median on reference host; investigate >10 ms delta | 20 interleaved before/after launches; report p50/p95, no cherry-picking |
| Dormant workbench overhead | <=2 ms median delta, no providers loaded | Clean minimal host paired with/without entrypoint |
| First interactive view shell | <=50 ms p95 warm filesystem | Action invocation to visible navigable shell; directory data may still load |
| First directory page | <=100 ms p95 for 1,000 immediate entries on local reference disk | No recursive scan; record OS cache state |
| Cached selection/render | <=8 ms p95; no single slice >16 ms on reference fixture | 1,000 cursor movements in 10,000 visible result items |
| Search first batch | <=150 ms p95 excluding explicit 80 ms debounce, warm 10k-file fixture | Report debounce and process startup separately |
| Stale-result rejection | Immediate at generation change | Deterministic late callback test |
| Cancellation cleanup | <=100 ms p95 for owned local rg process | Excludes uncooperative external LSP server; always invalidate callbacks immediately |
| Hidden/disabled providers | Zero active watchers/jobs/render timers | Scope inventory after idle grace |
| Search retention | <=10,000 items and <=16 MiB accounted payload per set; <=32 MiB total store | Track both item count and bytes; report process RSS separately |
| Preview | <=256 KiB and <=2,000 lines per preview | Oversized/binary input shows bounded/unsupported state |
| Lifecycle stability | No upward owned-handle count after 100 cycles | Forced GC for Lua allocation comparison; RSS reported with allocator caveat |

Accounted payload limits are not claims about exact Lua heap size. Benchmark actual RSS/GC allocation and detect growth. Cancel or truncate producers before model queues exceed bounds. A render budget does not allow a 100 ms synchronous JSON parse before rendering.

Fixture tiers: tiny 100 files; normal 10,000 files across nested folders with about 20 MiB text; stress 100,000 files/about 200 MiB text; pathological directory with 20,000 immediate entries and a 10 MiB single line. Generate deterministic contents and include match-dense, no-match, ignored, symlink and inaccessible cases. The stress tier proves bounded degradation; absolute first-batch target applies only to the named normal fixture.

Measure blank startup, opening a source file, first InsertEnter, first save before InsertEnter, first tree open, first search, and active streaming responsiveness. Startup marker timings alone miss scheduled work. Record wall time to first usable input and first frame where the test harness supports it; no inferred UI-ready claim from `vim.schedule()`.

Use fresh startup-log paths for each run because Neovim appends to existing files. Interleave baseline/candidate processes with identical Nix closure and plugin revisions. Report cold and warm cache conditions separately. Shared CI runners provide smoke and relative regression evidence; the host absolute threshold needs reference-host evidence.

## Mandatory Negative Cases

| Subsystem | Cases |
|---|---|
| Workspace | cwd differs from root; nested repo; submodule; symlink alias; two tabs; root disappears |
| Files | unreadable/missing dir; external rename; symlink cycle; 20k siblings; ignored empty dir; newline filename |
| Search | partial JSON chunk; bytes payload; invalid regex; leading dash query; missing rg; queue overflow; cancelled late exit |
| LSP | absent/unsupported client; two encodings; null result; partial error; detach mid-request; document changes; URI without local path |
| Navigation | closed origin; modified buffer; user split; preview close; repeated result traversal; stale location |
| Settings | false vs absent; unknown key; type/range error; read-only target; three toggles; unrelated hook survives |
| Mutations | destination collision; dirty buffer; changed preimage; partial copy/move; failed LSP edit; CRLF/file mode |
| Persistence | corrupt JSON; wrong schema; stale paths; write failure; two sessions; no auto-run recovered operations |

## Evidence Format

`docs/evidence/WB-NN.json` is the machine-readable record; use the neighboring template for narrative detail. Required fields: task, revision, environment, summary, gates. Each gate record has id, status, command, result, and artifacts. `status` must be `pass` for task completion. A command may be an explicit manual inspection procedure for a UX/ownership gate; do not fabricate a shell command for a human action. Artifact paths must exist inside the plugin repo. Detailed logs can be summarized with a reproducible fixture/command and an externally accessible CI run URL in result text; do not commit enormous generated fixtures.

Revision records the tested code commit(s) or a precise dirty-tree description plus diff artifact. Evidence updates themselves can be committed afterward; they must not obscure which code was tested. Cross-repository gates list every relevant commit in the environment/summary. The validator cannot detect forged evidence, so review must assess it.

## Release Gate

Exploration release requires WB-01 through WB-11 and applicable integration gate WB-25 when installed as the host default. Discovery release adds WB-12 through WB-17. Full core workbench adds WB-18 through WB-26. The machine manifest has explicit milestone memberships; a completion check must use those IDs, not infer readiness from task numbering.

Follow-on tasks are deferred with reasons and do not block the named core release. No unresolved data-loss, stale-callback, focus-loss or unbounded-resource issue can be waived for core release. Known platform limitations are published and reflected in capability states. Default enablement requires actual host walkthroughs, not only standalone tests.
