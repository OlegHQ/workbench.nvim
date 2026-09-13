# WB-25 opt-in Nix build evidence

Neovim is not enabled through Nix by default on this host. These checks exercise
only the opt-in flake package and the configured macOS system derivation with
`WITH_NVIM=1`; no activation or switch was run.

The standalone package build passed with exit status 0:

```sh
nix build .#nvimconf --no-link --no-write-lock-file \
  --override-input workbench-nvim path:/private/tmp/workbench-nix-flat.kw8RDD
```

The resulting `/nix/store/xb60l4xb2fdwih806p0hhm8946df9y91-nvimconf` contains
both `pack/plugins/start/workbench.nvim/lua/workbench/init.lua` and
`pack/plugins/start/workbench.nvim/plugin/workbench.lua` at the expected paths.

The actual macOS system derivation and Home Manager generation passed with exit
status 0 and built `darwin-system-26.05.c3e90c8.drv`:

```sh
WITH_NVIM=1 NIXPKGS_ALLOW_UNFREE=1 nix build \
  .#darwinConfigurations.mac.system --no-link --impure --no-write-lock-file \
  --override-input nvimconf path:/private/tmp/nvim-nix-input.JWc0AI \
  --override-input nvimconf/workbench-nvim \
    path:/private/tmp/workbench-nix-flat.kw8RDD
```

The resulting Home Manager generation was
`/nix/store/1m50apay2wlg6vjxxfv1jh45mgjp2xam-home-manager-generation`; its
`home-files/.config/nvim/pack/plugins/start/workbench.nvim` contains both the
module and plugin entrypoint at the expected paths. The root and plugin source
copies were staged without `.git`, `.bench-output`, `.test-output`, `.test-deps`,
and the nested `nixos-config` checkout. An initial incorrectly nested temporary
source was caught by inspecting its output and rejected; these passing checks
use the corrected flat plugin source.

The local runtime override is necessary because the locked upstream Workbench
input still resolves to planning-only SHA
`0534135d877ec3679bb91ee0b4a68b71e174ff7a`. Consequently this is Nix
packaging/build evidence, not published revision parity, a clean recursive
clone, or host activation evidence.
