---
name: workbench-implementation
description: Implement, validate, or review a workbench.nvim milestone using its task graph, shared architecture contracts, ownership boundaries, and performance gates. Use for workbench development, not ordinary theme or editor-setting changes.
---

# Workbench Implementation

Find the plugin repository by locating `docs/tasks.json` alongside `AGENTS.md`; paths below are relative to that repository. This works both in a standalone clone and in `nvim-config/pack/plugins/start/workbench.nvim`.

## Start

Read `AGENTS.md`, [the plan](../../../docs/PLAN.md), [architecture](../../../docs/ARCHITECTURE.md), and [validation gates](../../../docs/VALIDATION.md). Run `python3 scripts/check_plan.py --next` from the plugin root. Preserve the current user scope: planning, one task, a milestone, or review.

Select a task whose dependencies are done. If a prerequisite is unfinished, implement the prerequisite only when it belongs to the requested scope; otherwise report the specific dependency. Do not bypass a gate by renaming a task, weakening a threshold, or marking a test skipped. Claim the task with a named assignee and identify the repositories/files it owns before edits.

## Load Relevant Detail

- All runtime changes: [contracts](../../../docs/CONTRACTS.md).
- Explorer, search, symbols, results, navigation: [UX](../../../docs/UX.md) and [providers](../../../docs/PROVIDERS.md).
- Settings, completion, formatting, Nix, theming, releases: [integration](../../../docs/INTEGRATION.md).
- A disputed design or new dependency: [research](../../../docs/RESEARCH.md) and [decisions](../../../docs/DECISIONS.md).
- Completing a task: [evidence template](../../../docs/evidence/TEMPLATE.md), plus the task's acceptance criteria in the plan.

Read the actual implementation before applying the specification. If source behavior contradicts a design assumption, record the observation, update the affected ADR/contracts/tasks together, and continue with the smallest justified change. Do not silently invent a second model or owner.

## Implementation Rules That Prevent Drift

Use explicit constructors and injected service interfaces. Keep one composition root; no service locator, dynamic plugin discovery, universal event bus, or deep-copying global state on every update. Introduce shared abstractions when at least two concrete consumers need them; the plan's contracts establish boundaries, not a requirement to create every proposed file at once.

Providers publish typed data, views render projections, navigation opens locations, and scopes dispose resources. All asynchronous completions check scope liveness and request generation. Every feature has a real disabled path. Every unavailable action has a reason. Test at least one relevant stale/error/cleanup path alongside successful behavior.

For feature work, start from the task's user-visible scenario and finish it end to end. Native APIs, rg, Git, and existing optional picker adapters are implementation tools; replacing them requires comparative evidence. A narrow read-only explorer is intentional until the filesystem-operation task passes its mutation gates.

## Finish

Run applicable tests and benchmarks, record commands and results in a task evidence file, link it in `docs/tasks.json`, and run `python3 scripts/check_plan.py`. The validator checks evidence structure and dependencies; inspect whether evidence actually proves the behavior. Only then mark done. A review must check ownership/disposal and runtime performance as well as feature output.

If publishing is authorized, follow the integration runbook: plugin first, parent pointer second, Nix pin at the matching released commit. Do not infer permission to publish unrelated repositories from a task claim. Leave a resumable report with completed task IDs, evidence paths, outstanding blockers, and the next dependency-ready task.
