{
  description = "Up-to-date Ollama package and NixOS module, built from official binaries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
  let
    # List to be extended when arm64 support is validated.
    supportedSystems = [ "x86_64-linux" ];
    forEachSystem = f: nixpkgs.lib.genAttrs supportedSystems f;
  in
  {
    # ── Package outputs ────────────────────────────────────────────────────
    packages = forEachSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        ollama-bin = pkgs.callPackage ./pkgs/ollama.nix {};
        default    = self.packages.${system}.ollama-bin;
      });

    # ── Overlay ────────────────────────────────────────────────────────────
    # Injects ollama-bin into pkgs for consumers who prefer the overlay pattern,
    # and for the NixOS module to reference without a fragile relative path.
    overlays.default = final: prev: {
      ollama-bin = final.callPackage ./pkgs/ollama.nix {};
    };

    # ── NixOS module ───────────────────────────────────────────────────────
    # Applies the overlay automatically so users do not need to wire it
    # separately — importing the module is the only required step.
    nixosModules.default = { ... }: {
      imports = [ ./modules/ollama.nix ];
      nixpkgs.overlays = [ self.overlays.default ];
    };
  };
}