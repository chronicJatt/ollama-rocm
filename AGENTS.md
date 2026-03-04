# Agent Instructions — ollama-rocm

## Repository Purpose

This repo provides a NixOS flake that packages Ollama from official pre-compiled
binaries rather than source. The two deliverables are:

- `pkgs/ollama.nix` — the derivation, exposed as `pkgs.ollama-bin` via overlay
- `modules/ollama.nix` — a NixOS service module (`services.ollamaLocal`)

The primary audience is NixOS users on AMD (ROCm) hardware who cannot wait for
the nixpkgs package to catch up to upstream Ollama releases.

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

## Architecture Decisions

**Why binary fetch, not source build.** The nixpkgs source build couples the Go
compilation, ROCm library linking, and Nix store symlink resolution in a way
that breaks with each ROCm package update. The official tarballs ship a
self-contained ROCm runner (`lib/ollama/rocm/`) with its own bundled rocblas
kernels, removing any dependency on system ROCm paths.

**Why two tarballs.** Ollama's own `install.sh` performs two separate downloads
for AMD GPU systems. The base tarball (`ollama-linux-${arch}.tar.zst`) provides
the server binary. The ROCm tarball (`ollama-linux-${arch}-rocm.tar.zst`)
provides the GPU runners. A CPU-only install results from fetching only the
first — this is the silent failure mode to be aware of.

**Why `LD_LIBRARY_PATH` includes `rocmPackages.clr`.** The ROCm tarball bundles
rocblas kernels and a handful of shim libraries, but not `libhsa-runtime64.so`
— the HSA runtime that bridges the runner to the GPU hardware. This must come
from the system ROCm closure. Without it, the runner silently falls back to CPU.

**Why `HSA_OVERRIDE_GFX_VERSION`.** Consumer RDNA2 GPUs (gfx1031) are not
listed in the rocblas kernel manifest. The override causes the HSA runtime to
report a supported revision (10.3.0), causing the runner to select the gfx1030
fallback kernels. This is correct and expected behaviour for these GPUs.

**Why a separate `ollama-load-models.service`.** `ollama pull` is a client
command that requires a running server. It cannot be run in `ExecStartPre`
because the daemon has not yet started at that point. A `Type=oneshot` service
with `After=ollama.service` is the correct systemd pattern.

---

## Updating to a New Ollama Release

1. Update `version` in `pkgs/ollama.nix`.
2. Prefetch both hashes:

```bash
nix-prefetch-url https://ollama.com/download/ollama-linux-amd64.tar.zst
nix-prefetch-url https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst
```

3. Update both `sha256` fields in `pkgs/ollama.nix`.
4. Build and verify before committing:

```bash
nix build --impure --expr \
  'with import <nixpkgs> {}; callPackage ./pkgs/ollama.nix {}'

# All entries must resolve into the Nix store — no "not found"
ldd result/bin/ollama

# Smoke test
result/bin/ollama --version
```

5. Update the version badge in `README.md` and the `Tested Configurations` table
   if the status has changed.

---

## Module Conventions

Follow the NixOS module system conventions throughout:

- Options are declared under `options.services.ollamaLocal`.
- All implementation is gated behind `lib.mkIf cfg.enable`.
- The `endpoint` option is read-only and derived — consumers read it rather than
  reconstructing `host:port` themselves. This is the single source of truth for
  the API URL across the entire system configuration.
- `rocmGfxOverride` defaults to `""` and is omitted from the environment when
  empty, so CPU-only and NVIDIA users are not forced to set it.
- `StateDirectory` declares all required paths so systemd creates and owns them
  before the service starts. Never rely on manual `mkdir` or `chown`.

---

## Testing Checklist

After any change to `pkgs/ollama.nix`:

```bash
# 1. Build succeeds
nix build --impure --expr 'with import <nixpkgs> {}; callPackage ./pkgs/ollama.nix {}'

# 2. No broken dynamic links
ldd result/bin/ollama   # zero "not found" entries

# 3. Correct version reported
result/bin/ollama --version
```

After any change to `modules/ollama.nix`, test via a NixOS rebuild before
committing. The expected post-deploy verification sequence:

```bash
systemctl status ollama
journalctl -u ollama -n 50

# Confirm GPU acceleration — library=cpu indicates a fallback failure
journalctl -u ollama | grep "inference compute"

# Confirm VRAM climbs during inference
watch -n1 rocm-smi
ollama run qwen3.5:9b "explain pytorch autograd in one sentence"
```

---

## Known Limitations

- `aarch64-linux` is declared in the `archMap` but untested. Hash values in
  `pkgs/ollama.nix` are for `x86_64-linux` only. Contributions welcome.
- CUDA runners are present in the base tarball but are not tested or supported
  by this flake. NVIDIA users should use the nixpkgs package.
- The `sleep 2` guard in `ollama-load-models.service` is a pragmatic workaround
  for the socket-readiness race. A polling loop would be more robust but is not
  implemented.