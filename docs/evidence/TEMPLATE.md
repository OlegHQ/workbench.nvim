# Task Evidence Template

Create `WB-NN.json` for the completed task. The example below is a schema example, not evidence. Replace every example value with the observed result; do not copy a passing status without executing the check.

```json
{
  "task": "WB-01",
  "revision": "tested code commit or dirty-tree description plus diff artifact",
  "environment": "OS, Neovim, dependency versions, fixture revision, relevant repository SHAs",
  "summary": "Behavior established and any measured limitations",
  "gates": [
    {
      "id": "G0",
      "status": "pass",
      "command": "Actual command or precise manual review procedure",
      "result": "Observed outcome, counts, timings or reviewed ownership conclusion",
      "artifacts": []
    }
  ]
}
```

Include all gates required by the task, not just G0. A skipped, failed or unrun required gate means the task remains unfinished. Optional artifacts use repository-relative paths. Include the user journey IDs, exact benchmark fixture and p50/p95 values where relevant. State any unavailable environment without inventing a pass.

For a blocked task, record the blocker and next action in `docs/tasks.json`; an evidence file may record partial progress, but cannot make a blocked dependency ready.
