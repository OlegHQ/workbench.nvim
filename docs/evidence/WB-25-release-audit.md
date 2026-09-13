# WB-25 release and platform state audit

Checked locally on 2026-09-13. No commits, pushes, publication, host activation,
VM reset, or VM provisioning were performed.

## Published refs

```text
git ls-remote --symref git@github.com:OlegHQ/workbench.nvim.git HEAD 'refs/heads/*' 'refs/tags/*'
ref: refs/heads/dev    HEAD
0534135d877ec3679bb91ee0b4a68b71e174ff7a    HEAD
0534135d877ec3679bb91ee0b4a68b71e174ff7a    refs/heads/dev

git ls-remote --symref git@github.com:OlegHQ/nvim-config.git HEAD refs/heads/dev
ref: refs/heads/dev    HEAD
64dceb4df6ac4d3e9b571146101c00947c143b12    HEAD
64dceb4df6ac4d3e9b571146101c00947c143b12    refs/heads/dev
```

The Nix input lock points Workbench at the published planning-only commit
`0534135d877ec3679bb91ee0b4a68b71e174ff7a`; no published runtime SHA is
available to pin. The actual `nixos-config` checkout is clean on `dev` at
`5cee912f61aa99704a888b8140690d8a465c52a6`.

## Linux host availability

Multipass 1.16.3 reports the persistent `main` VM running Ubuntu 24.04.4 LTS.
`multipass exec main -- uname -a` and `multipass exec -vvvv main -- uname -a`
both fail with `ssh connection failed: 'Failed to connect: No route to host'`.
The host can ping `192.168.252.2` and open TCP port 22, but the Multipass
management path still cannot execute a guest command. No VM state was changed;
the Linux runtime gate remains unverified.

## Nix scope

The local Home Manager/system derivation passed with `WITH_NVIM=1`, using the
unpublished runtime through a local path override, and its generated files
contain the expected plugin entrypoint and public module. Per the actual
`make help`, `WITH_NVIM` defaults to `0`; no Nix activation was run. This does
not establish published lock parity, a fresh recursive clone, or rollout.
