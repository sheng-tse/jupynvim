{
  description = "jupynvim — Jupyter notebooks in Neovim with VSCode-style UX";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        jupynvim-core = pkgs.rustPlatform.buildRustPackage {
          pname = "jupynvim-core";
          version = "0.1.0";
          src = ./core;
          cargoLock = {
            lockFile = ./core/Cargo.lock;
          };
          meta = with pkgs.lib; {
            description = "Native backend for jupynvim";
            homepage = "https://github.com/sheng-tse/jupynvim";
            license = licenses.mit;
            mainProgram = "jupynvim-core";
          };
        };

        # Neovim plugin derivation: Lua files + binary symlinked at the path
        # that lua/jupynvim/init.lua's locate_core() looks for:
        #   <plugin_root>/core/target/release/jupynvim-core
        jupynvim = pkgs.vimUtils.buildVimPlugin {
          pname = "jupynvim";
          version = "0.1.0";
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            # Only include runtime Lua files; Rust source and CI config are
            # not needed in the plugin store path.
            filter = path: type:
              let rel = pkgs.lib.removePrefix (toString ./. + "/") path;
              in !(pkgs.lib.hasPrefix "core" rel)
                 && !(pkgs.lib.hasPrefix ".github" rel)
                 && rel != "flake.nix"
                 && rel != "flake.lock";
          };
          postInstall = ''
            mkdir -p $out/core/target/release
            ln -s ${jupynvim-core}/bin/jupynvim-core \
              $out/core/target/release/jupynvim-core
          '';
          meta = with pkgs.lib; {
            description = "Jupyter notebooks in Neovim with VSCode-style UX";
            homepage = "https://github.com/sheng-tse/jupynvim";
            license = licenses.mit;
          };
        };
      in
      {
        packages = {
          inherit jupynvim-core jupynvim;
          default = jupynvim;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            rust-analyzer
            clippy
            rustfmt
          ];
        };
      }
    ) // {
      # Overlay to inject the packages into a nixpkgs instance.
      # Add to nixpkgs.overlays and then reference as
      #   pkgs.vimPlugins.jupynvim  or  pkgs.jupynvim-core
      overlays.default = final: prev: {
        jupynvim-core = self.packages.${final.system}.jupynvim-core;
        vimPlugins = prev.vimPlugins // {
          jupynvim = self.packages.${final.system}.jupynvim;
        };
      };
    };
}
