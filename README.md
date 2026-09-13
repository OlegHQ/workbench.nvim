# workbench.nvim

A keyboard-first workspace workbench for Neovim: persistent exploration, resumable search, code discovery, and dependable feature controls.

**Status: local runtime implementation under integration validation; not yet published or enabled by default.** The public `:Workbench` command reports status by default. Run `:Workbench enable` explicitly to open Files or Search; `:Workbench disable` disposes Workbench-owned views and providers. The default setting remains disabled.

Repository: `OlegHQ/workbench.nvim`, development branch `dev`.

## Start Here

- [Implementation plan](docs/PLAN.md): delivery sequence and task specifications.
- [Architecture](docs/ARCHITECTURE.md): unified model, composition, ownership, and lifecycle.
- [Research](docs/RESEARCH.md): evidence, alternatives, and decisions.
- [UX contracts](docs/UX.md): precise user-visible behavior.
- [Agent instructions](AGENTS.md) and [implementation skill](.agents/skills/workbench-implementation/SKILL.md).
- [Validation](docs/VALIDATION.md): ownership, completion, correctness, performance, and release gates.

Run the planning checks with Python 3.11+:

```sh
python3 scripts/check_plan.py
python3 scripts/check_plan.py --next
python3 -m unittest discover -s tests -p 'test_*.py'
```

These commands validate planning structure only. They do not prove runtime behavior or host installation.

Set up the ignored, development-only dependencies and run the local harness with:

```sh
make bootstrap
make test
make test-integration
make test-ui
make test-e2e
make bench
make check-ownership
```

The harness checks Neovim 0.11.7 and the host binary. Runtime and E2E suites exercise the local implementation; they do not prove a published Nix installation. Benchmark fixtures and logs stay under ignored `.bench-output/` and `.test-output/` directories.

All validation is local; there is no GitHub CI. WB-01 establishes the local Neovim harness, including `make test-e2e` for real RPC UI input, rendered grids, focus and cleanup. Feature tasks must add provider and user-journey scenarios; the initial probe does not establish feature acceptance.

Suggested implementation request:

```text
Use $workbench-implementation. Read AGENTS.md and docs/PLAN.md, run the planning
validator, and implement the next dependency-ready task. Honor its repository
ownership and gates. Record reproducible evidence and update task status only
after all applicable gates pass. Continue through the requested milestone.
```

The plugin works independently of `autoconf.nvim` and `themekit.nvim`; those integrations add TOML settings and semantic theme mappings. In the nvim-config workspace it is a native Git submodule. Runtime publication, Nix installation wiring, exact revision parity, and host rollout remain gated integration work.
