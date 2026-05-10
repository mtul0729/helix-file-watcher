{
  description = "Helix Steel plugin for reloading files changed on disk";

  inputs = {
    crane = {
      url = "github:ipetkov/crane";
    };

    helix = {
      url = "github:mattwparas/helix/steel-event-system";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      crane,
      helix,
      nixpkgs,
    }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          craneLib = crane.mkLib pkgs;

          commonArgs = {
            pname = "helix-file-watcher";
            version = "0.1.0";

            cargoLock = ./Cargo.lock;
            outputHashes = {
              "git+https://github.com/mattwparas/steel.git#524bd81fbf7220c38941444cfda4d393206db2e5" =
                "sha256-HUJkeTYjIOn9ig874UOIWaXNBLEmEL7JHAr4oa9AZeg=";
            };

            doCheck = false;
          };

          cargoArtifacts = craneLib.buildDepsOnly (
            commonArgs
            // {
              src = craneLib.cleanCargoSource self;
            }
          );
        in
        rec {
          helix-file-watcher = craneLib.buildPackage (
            commonArgs
            // {
              src = self;
              inherit cargoArtifacts;

              installPhase = ''
                runHook preInstall

                dylib="$(find target -name libhelix_file_watcher.so -type f | head -n 1)"
                install -Dm755 "$dylib" $out/lib/libhelix_file_watcher.so
                install -Dm644 cog.scm $out/share/steel/cogs/helix-file-watcher/cog.scm
                install -Dm644 file-watcher.scm $out/share/steel/cogs/helix-file-watcher/file-watcher.scm
                install -Dm644 helix-file-watcher.scm $out/share/steel/cogs/helix-file-watcher/helix-file-watcher.scm

                runHook postInstall
              '';

              meta = {
                description = "Helix Steel plugin for reloading files changed on disk";
                homepage = "https://github.com/mtul0729/helix-file-watcher";
                license = pkgs.lib.licenses.mit;
                platforms = pkgs.lib.platforms.linux;
              };
            }
          );

          default = helix-file-watcher;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          helixPackage = helix.packages.${system}.default;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              rustfmt
              clippy
              rust-analyzer

              helixPackage
              zellij
              ripgrep
              util-linux
              procps
              gawk
            ];
          };
        }
      );
    };
}
