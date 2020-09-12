{ haskellNixSrc ? builtins.fetchTarball https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz
, haskellNix ? import haskellNixSrc {}
, nixpkgs ? haskellNix.sources.nixpkgs }:

let
  pkgs = import nixpkgs haskellNix.nixpkgsArgs;
in
  pkgs.mkShell {
    buildInputs = (with pkgs; [
      haskell.compiler.ghc883
      glibc glibc.static
      zlib zlib.static
      gmp5 gmp5.static
      gcc
      protobuf
      (libffi.overrideAttrs (old: { dontDisableStatic = true; }))
    ]) ++ (with pkgs.haskellPackages; [
      hlint
      hoogle
      cabal-install
      ghcid
      brittany
      apply-refact
      phoityne-vscode
      ghci-dap
      haskell-dap
      haskell-debug-adapter
    ]);

    shellHook = ''
      cabal update
    '';
  }
