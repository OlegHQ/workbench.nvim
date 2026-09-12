# Neovim Workbench Research

## Findings

The strongest opportunity is persistent exploration state and consistent navigation across capabilities. A sidebar alone addresses spatial orientation but does not solve resumable investigation, action discovery, shared search scope or trustworthy feature switches. The proposed workbench therefore owns these interactions while retaining native editing and domain engines.

Three design decisions follow. First, separate data providers from views and navigation. Second, share small explicit contracts rather than impose one universal tree object on every domain. Third, validate lifecycle and first-use latency alongside startup. These are project recommendations, not claims that a particular architecture is mandated by Neovim.

## Current Workspace Audit

The inspected root revision is `f5c5eaedcb2eb126ad0ec2c40dfc472100b81cba`. Autoconf is at `5a87cf0b40b43705357db892a1b07a40d418363c`; themekit is at `d023de449b4d906154975b3d180cfff70f75ba3c`. The local environment reports Neovim 0.12.4 and ripgrep 15.2.0. Existing root and plugin worktrees were clean at the start of planning. The GitHub root repository is public and defaults to `dev`.

| Observation | Evidence | Implication |
|---|---|---|
| Four principal Fzf commands are exposed | autoconf `sys/resolvers/command/init.lua`, file_picker/global_search/buffer_picker/diagnostics_picker | Existing engine can be retained; persistent workflow must be added |
| Diagnostics picker is document-only | `diagnostics_document()` | No exposed workspace Problems workflow |
| Files and grep use different option construction | `sys/resolvers/editor/filepicker.lua` | Define a shared scope/policy contract and parity tests |
| MiniFiles is configured and opened through public calls | `sys/resolvers/editor/mini_files.lua` and command resolvers | Optional adapter can coexist with a native sidebar |
| Completion booleans/length can log without changing Blink | `sys/resolvers/editor/completion.lua` | Settings lifecycle repair precedes settings UI |
| Formatting has two potential save owners | `sys/resolvers/editor/formatting.lua` plus `sys/defaults/lsp.lua` | Consolidate before runtime toggles |
| Blanket event deletion exists | formatting and LSP resolver disable paths | Add ownership groups and disposal regression tests |
| Keymaps generally lack descriptions | `sys/core/keymaps.lua` | Action registry metadata should generate discovery UI |
| Nested key parsing retains only final key and space prefix | `match_keymap_mode_keys()` | Multi-level key namespaces require a parser task or flat mappings |
| Completion capabilities are obtained after LSP registration in deferred setup | `sys/defaults/lsp.lua` | Verify startup negotiation before exposing completion guarantees |
| Plugin pins currently match local submodule revisions | `.gitmodules`, `flake.lock` | Preserve that consistency for runtime releases |
| Documented Nix host checkout is absent | no `nixos-config/` directory | Host activation cannot be claimed tested here |

A headless startup inspected active save hooks: auto-mkdir, final-newline insertion and an autoconf Conform formatting hook were registered. This verifies the active path but is not a full formatting test. Historical startup numbers conflict: AGENTS cited about 134 ms while OPTIMIZE cited about 92 ms. Neither is a fresh controlled benchmark. The 150 ms ceiling is a project target; WB-01 must collect reproducible baseline data.

The audit points to a configuration engine that has accumulated direct plugin setup and nominal settings. Building a UI over those settings would expose inconsistency. The plan separates repair work in autoconf from new workbench behavior and requires effective-state readback.

## Composition Patterns

VS Code declares commands, settings, views and other contributions through named contribution points. Its context conditions control when UI elements are applicable. The transferable idea is a discoverable registry with explicit context, not importing its extension host or reproducing its manifest system.[^1][^2]

For this project, use plain Lua action records and typed context snapshots. A palette, view help and default keymaps consume the same records. Capability predicates should read cached state; opening the palette must not trigger an LSP request for every action. Execution rechecks capability because context may change after the menu is displayed.

VS Code's Tree View API separates tree data from its presentation and supports view-specific operations.[^3] That supports the decision to isolate providers from renderers, but does not imply every domain should become a tree. Filesystem nodes have parent paths, symbols have source ranges, and call hierarchies have directed edges. A shared projection contract can retain those distinctions.

The selected composition style is explicit construction with injected services. Alternative designs include a service locator, a global event bus, a reducer for all application state, or independently configured plugins. They can work, but here each creates avoidable ambiguity around ownership, scheduling or shared context. Local state owners and typed subscriptions provide enough composition for the identified workflows. This judgment should be revisited only if a concrete extension cannot fit without duplication.

## Explorer Alternatives

| Approach | Fit for desired sidebar | Maintenance implication | Decision |
|---|---|---|---|
| Configure MiniFiles | Column navigation differs from a multi-branch tree | Small adapter if public APIs suffice | Keep optional file-edit action; run bounded docking experiment |
| Fork MiniFiles | Possible with substantial model/layout changes | Carry upstream patches and private lifecycle assumptions | Not selected without experiment evidence |
| Reuse Neo-tree | Existing split/sidebar and multiple sources | Adopt its state/rendering contracts and dependencies | Reference and fallback candidate |
| Reuse Snacks explorer | Explorer already shares picker infrastructure | Adopt broader picker composition | Reference and comparison candidate |
| Reuse Oil | Strong directory-as-buffer editing | Directory editing differs from persistent tree exploration | Optional future operation adapter |
| Focused workbench tree | Direct ownership of desired behavior | Must implement/tests filesystem reads and interaction | Selected initial architecture |

MiniFiles documents one explored branch in floating columns. The inspected local source's private `H.window_open` and `H.window_update` assign `relative = 'editor'`. Its public customization events do not establish a supported multi-branch split model. This makes geometry patching a poor foundation; it does not prove that no future MiniFiles API could support the workflow.[^4][^5]

Neo-tree explicitly supports sidebar, split and floating presentations, with filesystem, buffers and Git sources. It demonstrates that these capabilities can share a view system.[^6] No claim is made that it is slow: a comparison must measure identical fixtures and installed versions. The reason to own a renderer here is control of the unified model, not an unsupported performance assertion.

Snacks describes its explorer as a picker and exposes navigation, scoped grep, Git and diagnostic integration.[^7] It is a useful example of reusing a common interaction surface. The risk for this project is adopting a broader system before defining which component owns retained results and navigation history. WB-03 should compare behavior as well as dependency cost.

Oil treats a directory as an editable buffer and exposes its own actions/options.[^8] It is a stronger reference for operations than for a multi-branch project map. Reusing an operation adapter can be evaluated after the read-only exploration loop works; mutable directory buffers should not become the workbench's canonical filesystem model.

## Search And Result Navigation

Fzf-lua already supports per-call configuration and diverse picker behavior.[^9] The present config exposes a narrow subset, so replacing the fuzzy engine is not the first task. Workbench should retain a typed result model independent of a terminal picker, then let adapters expose quick selection without owning investigation state.

Ripgrep provides the search engine and ignore handling.[^10] Its structured JSON output supports raw-byte payloads and match offsets.[^11] That makes a streaming provider practical without parsing ambiguous human-readable lines. The implementation must still handle partial chunks, invalid regex, large lines, cancellation and output caps. Those are provider obligations, not performance benefits automatically conferred by using rg.

Neovim quickfix and location lists provide navigation and list history.[^12] They should remain compatible exports and native navigation paths. Replacing the global quickfix list whenever a sidebar selection changes would break other tools. Workbench owns its result-set IDs and exports an explicit snapshot to a newly identified list when requested.

Unsaved buffers are a distinct search problem. Disk search cannot claim to include current edits. The first release labels disk scope; later overlay work must use the same matcher semantics against captured buffer content. Workspace replacement should start with literal single-line operations, because reusing a different regex engine for replacement risks applying different matches than the user reviewed.

## Semantic Discovery

Native Neovim LSP clients expose request, cancellation and capability information.[^13] Workbench should consume those clients, preserving per-client provenance and encodings. Starting a separate client to populate an outline would duplicate language work and break configuration ownership.

The LSP data model distinguishes locations, location links, hierarchical/flat symbols and resolvable workspace symbols.[^14] The source under the 3.17 path also contains proposed later-version entries, so agents must reject proposed fields unless explicitly supported and tested. A URL containing a version is not sufficient proof that every field is stable.

Call hierarchy uses a preparation step and incoming/outgoing requests.[^15] A lazy graph projection therefore fits better than eager project indexing. Cycles and multiple edges are normal cases; node IDs must not collapse them into one path. Results need direction, origin and client payload to remain navigable.

Diagnostics are updated per buffer through the native diagnostic event.[^16] A Problems view can aggregate reported state but must state coverage limitations. No repository-wide clean bill of health should be inferred from zero known diagnostics. Code actions, hover and completion remain native or adapter-backed until a specific workbench UX requirement justifies replacement.

## Runtime And Resource Design

Neovim's API distinguishes byte-oriented positions and provides scheduled editor operations.[^17] The plan makes position encoding explicit and centralizes final cursor conversion. Display widths remain terminal-cell concerns, independent of source columns.

`vim.system` accepts argument arrays, streams and asynchronous completion; its `wait()` blocks.[^18] Interactive provider code must avoid waits and bound parsing work. Scheduling a large parser batch onto the main loop does not make it background work. Resource scopes and generation checks address lifetime correctness even when cancellation is advisory.

Filesystem event behavior varies across platforms.[^19] Watchers should be bounded, optional refresh hints with manual recovery. Git's porcelain output is designed for machine consumption and can use NUL delimiters.[^20] Batched status requests avoid process-per-row designs, and repository identity must account for submodules/worktrees.

## Capability Scope

| Capability | Core delivery | Later extension boundary |
|---|---|---|
| Files, search, results, previews, navigation | Required complete workflows | Alternative renderers |
| Outline, symbols, references, calls, Problems | Required subject to provider support | Syntax fallback and richer language-specific metadata |
| Settings and capability health | Required, including real disable behavior | New external feature adapters |
| Git | Read-only status/diff | Staging, discard, conflict UI, commits |
| Filesystem operations | Reviewed create/rename/move/copy/trash | Bulk text-edit operation UI |
| Replacement | Reviewed literal single-line | Regex captures and multiline |
| Session/workspaces | Single-root sessions; bounded persistence | Multi-root execution |
| Terminal/tasks | Explicit follow-on specification | Runner adapter; no startup task execution |
| Tests/debugging | Integration extension points | Test and DAP adapters with separate lifecycles |
| Remote files | Local filesystem only initially | URI/provider adapter, not path coercion |
| AI/indexing | Not required | Separate proposal with resource and privacy model |

The follow-on capabilities remain visible in the task graph as deferred work. They are not a reason to build a generic plugin framework before Files and Search work. Completion is defined by a named milestone, so a usable exploration release does not imply tasks/debugging are shipped.

## Evidence Limits And Revalidation

Research was accessed on 2026-09-12. Upstream documentation is rolling unless otherwise stated. Recorded comparison heads: mini.nvim `6664ea9af6c43dc31934e27476bbe61c556c8dc1`, Snacks `882c996cf28183f4d63640de0b4c02ec886d01f2`, Fzf-lua `05e44d38de0a79c11fba5f7bf8138791b1dbdd1e`, Neo-tree v3.x `1a14083046d96e88e361d1da00761c40d45012f3`. These identify investigation candidates, not approved runtime pins. The installed Nix MiniFiles source may differ; WB-03 records its store path/hash before experiments.

No comparative runtime benchmark or interactive docking experiment has yet been completed. Current conclusions combine source inspection with documented APIs. WB-01/WB-03 are mandatory validation tasks, and must retain negative results. There is no evidence supporting a blanket claim that a rewrite will be faster than existing explorers.

## Sources

[^1]: Microsoft, [Contribution Points](https://code.visualstudio.com/api/references/contribution-points), rolling documentation, accessed 2026-09-12.
[^2]: Microsoft, [When Clause Contexts](https://code.visualstudio.com/api/references/when-clause-contexts), rolling documentation, accessed 2026-09-12.
[^3]: Microsoft, [Tree View API](https://code.visualstudio.com/api/extension-guides/tree-view), rolling documentation, accessed 2026-09-12.
[^4]: MINI, [mini.files documentation](https://nvim-mini.org/mini.nvim/doc/mini-files.html), generated from main, accessed 2026-09-12.
[^5]: MINI, [mini.files source](https://github.com/nvim-mini/mini.nvim/blob/6664ea9af6c43dc31934e27476bbe61c556c8dc1/lua/mini/files.lua), comparison revision; local installed source additionally inspected.
[^6]: Neo-tree maintainers, [neo-tree help](https://github.com/nvim-neo-tree/neo-tree.nvim/blob/1a14083046d96e88e361d1da00761c40d45012f3/doc/neo-tree.txt), v3.x comparison revision.
[^7]: Folke, [Snacks explorer](https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/docs/explorer.md), comparison revision.
[^8]: Steve Arc, [Oil documentation](https://raw.githubusercontent.com/stevearc/oil.nvim/master/doc/oil.txt), rolling master, accessed 2026-09-12.
[^9]: Ibhagwan, [Fzf-lua options](https://github.com/ibhagwan/fzf-lua/blob/05e44d38de0a79c11fba5f7bf8138791b1dbdd1e/OPTIONS.md), comparison revision.
[^10]: Andrew Gallant and contributors, [ripgrep guide](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md), rolling master, accessed 2026-09-12.
[^11]: ripgrep contributors, [JSON printer protocol](https://github.com/BurntSushi/ripgrep/blob/master/crates/printer/src/json.rs), rolling master, accessed 2026-09-12.
[^12]: Neovim, [Quickfix](https://neovim.io/doc/user/quickfix/), rolling documentation, accessed 2026-09-12.
[^13]: Neovim, [LSP](https://neovim.io/doc/user/lsp/), rolling documentation, accessed 2026-09-12.
[^14]: Microsoft, [LSP meta-model](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/metaModel/metaModel.json), declares 3.17 with some proposed later entries, accessed 2026-09-12.
[^15]: Microsoft, [Call Hierarchy](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/callHierarchy.md), LSP 3.17 source, accessed 2026-09-12.
[^16]: Neovim, [Diagnostics](https://neovim.io/doc/user/diagnostic/), rolling documentation, accessed 2026-09-12.
[^17]: Neovim, [API](https://neovim.io/doc/user/api/), rolling documentation, accessed 2026-09-12.
[^18]: Neovim, [Lua and vim.system](https://neovim.io/doc/user/lua/), rolling documentation, accessed 2026-09-12.
[^19]: libuv, [Filesystem Event Handles](https://docs.libuv.org/en/v1.x/fs_event.html), v1.x documentation, accessed 2026-09-12.
[^20]: Git, [git-status](https://git-scm.com/docs/git-status), porcelain format, accessed 2026-09-12.
