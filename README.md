# ollama-rocm

A Nix flake providing same-day Ollama packages and NixOS service module,
built from Ollama's official pre-compiled binaries rather than from source.

The nixpkgs `ollama` package has chronically lagged behind upstream releases —
at the time of writing 25.11 ships v0.12.11 against an upstream of v0.17.5. This
gap is known and accounted for: the nixpkgs build compiles Ollama from source and
re-links the ROCm stack through Nix store symlinks, a process that breaks in
a new way with each ROCm package update and has kept the maintainers pinned to
an old revision. This flake takes a different approach entirely.

---

## How It Works

Rather than compiling from source, this derivation fetches the official Linux
tarballs that Ollama's own install script distributes. Crucially, for AMD GPU
systems it fetches **both** tarballs that the installer downloads:

```
ollama-linux-amd64.tar.zst       — server binary + CPU/CUDA runners
ollama-linux-amd64-rocm.tar.zst  — ROCm runners + bundled rocblas kernels
```

The ROCm tarball ships its own `libnuma`, `librocprofiler-register`, and the
full rocblas TensileLibrary kernel collection inside `lib/ollama/rocm/`. The
runner loads these co-located libraries at runtime rather than reaching out to
system ROCm paths. This is the key insight that makes nixpkgs's `symlinkJoin`
rocm-path approach unnecessary — and the source of most of its fragility.

The derivation unpacks both archives into the same output directory (their
`bin/` and `lib/ollama/` trees merge cleanly), patches the ELF interpreter and
`RPATH` of the main binary to point into the Nix store, and produces a
self-contained package ready for NixOS service declaration.

---

## Repository Structure

```
ollama-rocm/
├── flake.nix          # outputs: packages, overlays, nixosModules
├── flake.lock
├── README.md
├── AGENTS.md
├── pkgs/
│   └── ollama.nix     # fetchurl derivation — two tarballs, patchelf, archMap
└── modules/
    └── ollama.nix     # NixOS module — systemd service, options, user/group
```

---

## Why Not Upstream This to nixpkgs?

The nixpkgs maintainers are aware of the version lag and are working on it.
The source-build approach is the correct long-term path for nixpkgs because it
produces a fully reproducible, auditable derivation. The binary-fetch approach
taken here trades that auditability for immediacy — you are trusting Ollama's
release artifacts rather than building from a pinned source revision.

This flake is the right choice if you need a current version today. It is also
useful as a reference for the tarball structure and runtime library layout,
which may assist the nixpkgs effort. Contributions and issue reports on ROCm
compatibility across different GPU architectures are welcome.

---

## Requirements

- NixOS with Flakes enabled
- AMD GPU (RDNA architecture). The base package also works CPU-only; CUDA
  runners are present in the base tarball but untested here.
- For RDNA2 GPUs (e.g. RX 6700M, gfx1031): the `HSA_OVERRIDE_GFX_VERSION`
  environment variable must be set — the module handles this automatically via
  the `rocmGfxOverride` option.

---

## Usage

### Add the flake input

```nix
# flake.nix
inputs = {
  ollama-rocm.url = "github:chronicJatt/ollama-rocm";
};
```

### Import the NixOS module

```nix
# In your nixosConfigurations modules list:
inputs.ollama-rocm.nixosModules.default
```

### Configure the service

```nix
services.ollamaLocal = {
  enable     = true;
  host       = "127.0.0.1";
  port       = 11434;
  loadModels = [ "qwen3.5:9b" ];

  # Required for RDNA2 (gfx1031). Omit or adjust for other architectures.
  rocmGfxOverride = "10.3.0";
};
```

That is the complete configuration. No `services.ollama`, no manual ROCm
symlink rules, no `environment.variables` entries required.

---

## NixOS Module Options

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the Ollama service |
| `host` | string | `"127.0.0.1"` | Bind address for the API server |
| `port` | port | `11434` | Port for the API server |
| `endpoint` | string | *(read-only)* | Canonical `http://host:port` URL, derived from `host` and `port` for use by other modules |
| `loadModels` | list of string | `[]` | Models to pull automatically after the service starts |
| `rocmGfxOverride` | string | `""` | Value for `HSA_OVERRIDE_GFX_VERSION`. Required for consumer RDNA2 GPUs |

### The `endpoint` option

The `endpoint` option is read-only and computed from `host` and `port`. Its
purpose is to give other NixOS or Home Manager modules a single canonical
source of truth for the API address, so they do not need to reconstruct it:

```nix
# In a Home Manager module that consumes the Ollama API:
{ config, ... }:
{
  # Works correctly whether Ollama is local or remote —
  # the calling host never needs to know which.
  programs.opencode.ollamaUrl = config.services.ollamaLocal.endpoint;
}
```

---

## Multi-Host / Remote Inference

A common workflow is to run inference on a dedicated machine while keeping the
coding agent on a development laptop. This module is designed to make that
transition a single-line change per host.

**On the inference server** (e.g. a Proxmox VM or headless workstation):

```nix
services.ollamaLocal = {
  enable     = true;
  host       = "0.0.0.0";    # accept connections from the network
  port       = 11434;
  loadModels = [ "qwen3.5:9b" ];
};
```

**On the development machine** (where the coding agent runs):

```nix
# Disable local inference
services.ollamaLocal.enable = false;

# Point the agent at the remote host directly.
# If using the endpoint option pattern, only this line changes:
programs.myAgent.ollamaUrl = "http://192.168.1.x:11434";
```

No changes to the agent configuration, no service restarts beyond the rebuild.
The `endpoint` option pattern makes this even cleaner — the agent module reads
`config.services.ollamaLocal.endpoint`, so flipping from local to remote
requires updating only the `host` option.

---

## Model Loading

Models declared in `loadModels` are managed by a separate oneshot systemd
service (`ollama-load-models.service`) that runs after the main daemon reaches
active state. Each model is pulled sequentially. The service uses
`RemainAfterExit = true`, so `systemctl status ollama-load-models` will report
active after all pulls complete and remain queryable across reboots.

The service is only created when `loadModels` is non-empty.

---

## Updating the Package Version

When Ollama releases a new version:

1. Update the `version` string in `pkgs/ollama.nix`.
2. Prefetch the new tarballs to obtain updated hashes:

```bash
nix-prefetch-url https://ollama.com/download/ollama-linux-amd64.tar.zst
nix-prefetch-url https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst
```

3. Update the `sha256` fields in `pkgs/ollama.nix`.
4. Run the build test before committing:

```bash
nix build --impure --expr \
  'with import <nixpkgs> {}; callPackage ./pkgs/ollama.nix {}'
ldd result/bin/ollama   # confirm no "not found" entries
```

The `.tar.zst` format is the primary distribution format as of v0.17.x. A
`.tgz` fallback is provided for older version pins via the `useZst` boolean in
the derivation.

---

## Tested Configurations

| GPU | Architecture | `rocmGfxOverride` | Status |
|---|---|---|---|
| RX 6700M | RDNA2 (gfx1031) | `"10.3.0"` | ✓ Testing |

Additional configurations welcome via pull request or issue.

---

## Acknowledgements

The nixpkgs `ollama` package and its maintainers provided the map of pitfalls
this derivation navigates around. The Ollama project's own `install.sh` script
was the primary reference for understanding the two-tarball distribution model
and the AMD GPU code path.
