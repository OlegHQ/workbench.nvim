# Host Integration And Release

## Repository Boundaries

| Repository | Owner | Runtime relationship |
|---|---|---|
| `OlegHQ/workbench.nvim`, dev | Workbench model, views/providers/actions and this specification | Standalone native plugin |
| `OlegHQ/autoconf.nvim`, dev | TOML, language configuration, editor feature lifecycle | Optional public workbench adapter |
| `OlegHQ/themekit.nvim`, dev | Theme resolution and semantic highlight mappings | Optional theme integration |
| `OlegHQ/nvim-config`, dev | User defaults, mappings, submodule gitlinks and Nix module | Host composition |
| `OlegHQ/nixos-config`, main | Third-party packages/binaries and host activation | Separate checkout; absent during planning |

Locate repositories from actual Git state. The Nix checkout's documented path is `nixos-config/`; if absent, inspect known workspace configuration or ask for its location only when activation is the remaining dependent task. Do not create a fake checkout or claim `make switch` passed. Complete independent plugin tests first.

## Current Planning Delivery

The planning repository has no runtime entrypoint. Adding its submodule makes docs/skills available without enabling features. Runtime flake wiring is intentionally WB-25. Do not install an empty plugin as evidence of runtime completion. Run the plan validator and its negative tests locally. Do not add GitHub Actions or other hosted CI; runtime integration acceptance uses local Neovim end-to-end tests.

Use `git@github.com:OlegHQ/workbench.nvim.git` in `.gitmodules`, `branch = dev`, and Git mode 160000 for the path. The parent's broad `pack` ignore rule means adding the submodule may require `git submodule add -f`; do not remove that ignore rule or stage raw plugin files. Gitlinks record exact commits; branch tracking is only an update policy. [Git submodules](https://git-scm.com/docs/git-submodule).

## Autoconf Repairs Before Integration

WB-02 owns these changes in autoconf, not in workbench:

1. Completion settings must reach the actual Blink configuration. Test auto-completion false/true, keyword length, path source, preview insert and snippets against the installed version's documented API. Preserve user overrides. Report unsupported fields instead of logging success.
2. Establish one save-format owner. Lazy-load formatting on the first relevant format/save action, including normal-mode edits followed by write before InsertEnter. Do not eagerly require Conform during option resolution or register a second format hook inside deferred setup.
3. Replace blanket autocmd clearing with named groups/IDs and per-feature disposal. Test unrelated save/hover hooks survive disable and three enable-disable cycles do not duplicate effects.
4. Recheck completion capability negotiation before LSP initialization. Cheap capability generation may be eager if measured and necessary; deferring UI setup cannot mean advertising capabilities after the server already initialized. Configure through supported APIs, not global protocol monkey-patches.
5. Make LSP enable/disable reversible for the configured servers, preserving external clients. Stopping all clients is not a scoped setting implementation. Restore message/progress handlers only if the resolver still owns the installed handler; avoid global override where a local subscription suffices.
6. Correct soft-wrap false behavior and classify any other nominal resolver discovered by the audit. Do not expose a workbench toggle for an unverified setting. Add health output for requested/effective/restart-required state.

Tests must run inside isolated Neovim instances and also exercise the installed integration. Mocks alone cannot prove Blink/Conform option semantics. Any upstream API used must be verified against the pinned installed version during WB-02.

## TOML Translation

The following is a proposed schema for WB-19, not currently supported configuration:

```toml
[editor.workbench]
enable = true

[editor.workbench.sidebar]
position = "left"
width = 32
views = ["files", "outline", "problems"]
follow-active-file = false

[editor.workbench.search]
debounce-ms = 80
max-results = 10000
hidden = true
ignored = false
follow-symlinks = false

[editor.workbench.preview]
enable = true
max-bytes = 262144

[editor.workbench.session]
persist = true
max-results-history = 10
```

Translate known kebab-case fields explicitly into workbench's Lua schema. Do not recursively rewrite arbitrary strings or pass every unknown key through. Preserve false, distinguish absent keys, replace list values predictably, and validate numeric bounds before applying. Workbench publishes its config schema/defaults; autoconf handles translation and provenance rather than maintaining a second independent defaults table.

`workbench.setup()` validates/caches config without opening windows, scanning files or starting LSP/rg/Git. Disabled startup registers at most cheap discovery commands and performs no provider setup. A false enable state may still expose an explicit enable action; ordinary open actions cannot bypass it.

For editor features owned by autoconf, register setting adapters with getter/setter/capability/scope metadata. The workbench UI never calls Blink or Conform directly. Standalone workbench marks these host-specific controls unavailable or omits their contribution when no adapter is registered.

## Keymap Migration

Autoconf currently recognizes a space prefix but reduces paths to their last segment. WB-19 must either implement arbitrary prefix concatenation with regression tests for all modes or keep new mappings flat. Do not add `[keys.normal.space.w]` and assume `Space w ...` works.

Generate mapping descriptions from action metadata. Resolve user mapping precedence deterministically; report collisions without silently overwriting the user's binding. LSP-specific bindings use the actual attached buffer and method availability. Keep native motions and native jumplist keys unchanged.

Candidate migration after UX gates: `Space /` to workbench search, a new conflict-free action for sidebar, `Space f` kept as quick file pick, and MiniFiles retained on its existing actions until the user deliberately replaces them. Theme picker `Space t` remains owned by host configuration. Specify final keys in tests and docs at WB-25, not in providers.

## Theme Integration

Define semantic workbench groups: Normal, Selection, Muted, Border, Directory, Match, Error, Warning, Info, GitAdded, GitModified, GitDeleted, Disabled and Loading. Standalone defaults link to standard Neovim groups without hardcoded colors. Themekit maps these to existing Helix-compatible UI/diagnostic/diff tokens.

Test light and dark themes, no truecolor, missing icons, color scheme changes with views open, selection contrast and monochrome badge labels. Theme changes only update highlights; they must not invalidate provider caches or rebuild every result. Avoid adding hardcoded RGB values to workbench Lua.

## Nix Runtime Wiring At WB-25

Add a `workbench-nvim` input with `flake = false` and explicit dev tracking in the host flake. Wire both the Home Manager `xdg.configFile` plugin source and standalone package installation path, as the other custom plugins are wired. Optional runtime dependencies remain Nix-managed; do not fetch them in `setup()` or copy third-party directories into `pack/`.

After publishing runtime plugin changes, update only relevant inputs where supported (`nix flake update workbench-nvim`, and autoconf/themekit inputs if those changed). Targeted updates avoid unrelated nixpkgs churn. Verify the installed Nix CLI syntax, inspect the entire lock diff, and ensure locked revisions equal the intended published commits. [Nix flake update](https://nix.dev/manual/nix/2.28/command-ref/new-cli/nix3-flake-update).

The historical host flake inputs omit explicit dev refs for existing plugins. Align them during the integration task if needed; do not silently depend on a repository default branch remaining dev forever. Adding only the input is insufficient: both source-installation paths and enable configuration must be tested.

Run Nix evaluation/build before activation. On the actual host checkout, use its documented switch command only when integration work is authorized. Retain previous package generation and matching plugin commits as rollback references. A missing host checkout is a release gate blocker, not a unit-test failure and not permission to skip that gate.

## Publication Sequence

1. In every changed repository, inspect status and diff, identify task-owned files, run gates, and commit from that repository. Do not use `git add -A` in an unknown dirty worktree.
2. Push changed plugin commits to their intended branches. Confirm remote branch SHA with Git/gh.
3. In nvim-config, update gitlinks and relevant runtime flake pins; validate mode 160000, SSH URLs, dev tracking, and exact commit equality for runtime inputs.
4. Commit and push parent changes after plugin publication succeeds. Update downstream Nix host pin only from its own repository.
5. Verify a fresh recursive clone and a Nix-built runtime. Existing local checkouts can hide missing files or undeclared dependencies.
6. Record all repository SHAs in release evidence. Do not tag a runtime release while any required milestone task lacks gate evidence.

Planning documentation may be published without Nix runtime wiring, because it cannot be installed as a working feature. Once runtime code is distributed, docs-only plugin updates may leave the installed runtime pin unchanged if the release record explicitly identifies that choice; never claim gitlink/lock runtime parity without checking it.

## Rollout And Rollback

Default host workbench enablement stays false until the exploration release passes. Trial it with explicit commands in the real host, then enable the agreed capabilities in TOML. The rollback is disabling workbench and restoring prior mappings/config pins through ordinary new commits or the prior Nix generation. It is not resetting a dirty worktree.

The lifecycle gate must prove disabling restores the editor and releases owned runtime state. Persisted JSON can be ignored or migrated independently of editor files. No rollback may wipe buffers, delete the user's project files or remove unrelated autocommands.
