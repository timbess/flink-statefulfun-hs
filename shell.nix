{ nixpkgs ? import <nixpkgs> {}
, haskellNixSrc ? builtins.fetchTarball https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz
, haskellNix ? import haskellNixSrc {}
}:

let
  pkgs = import haskellNix.sources.nixpkgs haskellNix.nixpkgsArgs;
in
  pkgs.mkShell {
    buildInputs = (with pkgs; [
      haskell.compiler.ghc883
      glibc glibc.static
      zlib zlib.static
      gmp6 (gmp6.override { withStatic = true; })
      gcc
      protobuf
      wget
      curl
      git
      libffi
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
