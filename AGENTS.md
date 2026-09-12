# workbench.nvim Agent Contract

## Scope And Entry

This repository currently contains an implementation specification. Do not describe planned capabilities as shipped. Start with [docs/PLAN.md](docs/PLAN.md), run `python3 scripts/check_plan.py --next`, and use [.agents/skills/workbench-implementation/SKILL.md](.agents/skills/workbench-implementation/SKILL.md) for implementation or architectural review.

The user request determines whether to plan, implement one task, or complete a milestone. A planning request does not authorize building every milestone. Gates are evidence requirements, not repeated permission requests. Routine reversible work within an authorized implementation task should continue autonomously.

## Non-Negotiable Boundaries

- Workbench owns workspace exploration and its resources; autoconf owns editor configuration and existing completion/formatting/LSP setup; themekit owns theme mapping; nvim-config owns integration and gitlinks; Nix owns third-party installation.
- Implement the dependency direction and ownership table in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Providers never create windows, renderers never run providers, and reducers never perform I/O.
- Use the shared resource/location, result, action, and scope contracts in [docs/CONTRACTS.md](docs/CONTRACTS.md). Keep provider-specific data in typed payloads; do not erase LSP client identity, encoding, or hierarchy edge identity.
- Each handle, process, subscription, buffer, window, keymap, and autocommand has one named owner and idempotent disposal. Disabling a feature releases its owned runtime resources without removing another feature's state.
- No private APIs, monkey-patching another plugin's window internals, per-row processes, whole-repository scans on startup, shell-string interpolation, or synchronous process waits in interactive paths.
- Heavy imports and actual work begin on demand. `vim.schedule()` is main-loop scheduling, not background execution or proof of responsiveness.
- Native `start/` package discovery has costs. Keep the future entrypoint minimal and profile the complete host, first use, and active UI.
- Use scoped/buffer-local events. Necessary lifecycle events without file patterns must be listed in the event ownership inventory with an O(1) inactive path. Never blanket-clear autocommands.
- View buffers are projections, not databases. Navigation targets come from IDs, never reparsed display text. Preview cannot overwrite modified user buffers or add committed history entries.
- Preserve existing mappings until an integration task explicitly migrates them. Optional dependencies fail with an actionable capability state, not silent success.

## Delivery Discipline

1. Re-read relevant files and `git status` in every repository the task owns.
2. Select a dependency-ready task from [docs/tasks.json](docs/tasks.json). Claim it with `status: in_progress` and a nonempty `assignee`; module ownership remains the task's `owner` field.
3. Read only the task's linked specifications plus shared contracts and gates. Add or revise an ADR before a material contract change, with callers and migration impact.
4. Implement the user behavior and the failure/cleanup paths together. Do not satisfy a task with stubs, unconditional success, or tests that only assert text exists.
5. Run applicable gates from [docs/VALIDATION.md](docs/VALIDATION.md). Add an evidence file using [docs/evidence/TEMPLATE.md](docs/evidence/TEMPLATE.md). Record skips as skips, not passes.
6. Mark `done` only with completed dependencies and evidence for all required gates. `blocked` requires a concrete prerequisite and next action. Downstream tasks remain blocked by unfinished prerequisites.
7. Report changed behavior, tests, measured limits, and remaining work. Do not claim release completion from unit tests alone.

Do not spawn agents merely because this document mentions ownership. Delegation requires authorization from the active task or other applicable instructions. If delegated work is authorized, one writer owns each file/module at a time; integration must revalidate cross-module contracts.

## Repository And Release

Use remote `git@github.com:OlegHQ/workbench.nvim.git` and branch `dev`. Commit plugin changes from this repository. Never stage sibling plugin contents here. In the parent, stage the submodule gitlink, not plugin files. Publish the plugin commit before pointing a parent gitlink or Nix lock at it.

The initial planning revision is not a runtime release. Follow [docs/INTEGRATION.md](docs/INTEGRATION.md) before adding runtime TOML wiring or Nix input/install wiring. Do not run the parent's broad `make sync` as a shortcut. It stages unrelated changes and assumes a Nix checkout exists.

## Tests And Performance

All validation is local. Do not create GitHub Actions or other hosted CI workflows. Runtime feature acceptance requires local end-to-end tests through real Neovim instances; mocks and planning checks supplement that evidence, not replace it.

The existing Python checks cover planning artifacts only. Task WB-01 creates the Neovim runtime harness. Use pinned `mini.test` as a development-only dependency, or document an evidence-backed substitute before changing that choice. Do not install a test framework as a runtime dependency.

Respect the host's 150 ms startup target and investigate deltas above 10 ms. New workbench budgets, benchmark conditions, and negative scenarios are in [docs/VALIDATION.md](docs/VALIDATION.md). Unmeasured targets are not measurements. Do not move work past the startup marker merely to improve that number.
