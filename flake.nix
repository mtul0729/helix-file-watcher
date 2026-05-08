{
  description = "Helix Steel plugin for reloading files changed on disk";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
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
        in
        rec {
          helix-file-watcher = pkgs.rustPlatform.buildRustPackage {
            pname = "helix-file-watcher";
            version = "0.1.0";

            src = self;

            cargoLock = {
              lockFile = ./Cargo.lock;
              outputHashes = {
                "steel-core-0.8.2" = "sha256-HUJkeTYjIOn9ig874UOIWaXNBLEmEL7JHAr4oa9AZeg=";
              };
            };

            doCheck = false;

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
          };

          default = helix-file-watcher;
        }
      );
    };
}
