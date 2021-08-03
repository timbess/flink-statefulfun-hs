{ muslpkgs ? (import "${staticNix}/nixpkgs.nix").pkgsMusl
, nixpkgs ? import <nixpkgs> {}
, staticNix ? nixpkgs.fetchgit {
  url = "https://github.com/nh2/static-haskell-nix";
  sha256 = "0c104fqw6gyxbli8d59bkm9bm79svxf6q2zk5yx771kwfh6n4ij7";
  rev = "0e72ef1ba53a4db633862cae231fb90a1e052a02";
}
# { nixpkgs ? import <nixpkgs> {}
, haskellNixSrc ? builtins.fetchTarball https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz
, haskellNix ? import haskellNixSrc {}
}:

let
  pkgs = import haskellNix.sources.nixpkgs haskellNix.nixpkgsArgs;
in
  pkgs.mkShell {
    buildInputs = (with pkgs; [
      muslpkgs.haskell.compiler.ghc884
      muslpkgs.zlib.static
      (muslpkgs.gmp6.override { withStatic = true; })
      gcc
      protobuf
      wget
      curl
      git
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
