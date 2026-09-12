# workbench.nvim

A keyboard-first workspace workbench for Neovim: persistent exploration, resumable search, code discovery, and dependable feature controls.

**Status: implementation specification, not a working editor plugin.** This revision contains research, architecture contracts, agent instructions, a task graph, and planning validation. No runtime commands, sidebar, or providers have been implemented. There is no `plugin/` entrypoint to change editor startup.

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

These commands validate the implementation package. They do not test a workbench runtime that does not yet exist.

Suggested implementation request:

```text
Use $workbench-implementation. Read AGENTS.md and docs/PLAN.md, run the planning
validator, and implement the next dependency-ready task. Honor its repository
ownership and gates. Record reproducible evidence and update task status only
after all applicable gates pass. Continue through the requested milestone.
```

The plugin must also work independently of `autoconf.nvim` and `themekit.nvim`. In the nvim-config workspace it will be a native Git submodule, with TOML integration owned by autoconf and semantic theme mappings owned by themekit. Runtime integration is a later gated task.
