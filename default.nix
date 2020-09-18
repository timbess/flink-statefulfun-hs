{ # Fetch the latest haskell.nix and import its default.nix
  haskellNix ? import (builtins.fetchTarball "https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz") {}

# haskell.nix provides access to the nixpkgs pins which are used by our CI,
# hence you will be more likely to get cache hits when using these.
# But you can also just use your own, e.g. '<nixpkgs>'.
, nixpkgsSrc ? haskellNix.sources.nixpkgs-2003

# haskell.nix provides some arguments to be passed to nixpkgs, including some
# patches and also the haskell.nix functionality itself as an overlay.
, nixpkgsArgs ? haskellNix.nixpkgsArgs
# , nixpkgsArgs ? ( haskellNix.nixpkgsArgs // {
#     overlays = haskellNix.nixpkgsArgs.overlays ++ [
#       (self: super: {
#         haskell.packages.ghc883.proto-lens-protobuf-types = self.haskell.packages.ghc883.proto-lens-protobuf-types.
#       })
#     ];
#   })

# import nixpkgs with overlays
, pkgs ? import nixpkgsSrc nixpkgsArgs
}: let

package = pkgs.haskell-nix.cabalProject {
  # 'cleanGit' cleans a source directory based on the files known by git
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "flink-statefulfun";
    src = ./.;
  };
  
  modules = [
    {
      packages.proto-lens-protobuf-types.components.library.build-tools = [pkgs.protobuf];
    }
  ];

  # For `cabal.project` based projects specify the GHC version to use.
  compiler-nix-name = "ghc883"; # Not used for `stack.yaml` based projects.
};

new-proto-lens-protobuf-types = package.proto-lens-protobuf-types // {
  setup = (package.proto-lens-protobuf-types.setup.overrideAttrs (old: { buildInputs = old.buildInputs ++ [pkgs.protobuf]; }));
  src = (package.proto-lens-protobuf-types.src.overrideAttrs (old: { buildInputs = old.buildInputs ++ [pkgs.protobuf]; }));
};

in package # // { proto-lens-protobuf-types = new-proto-lens-protobuf-types; }