{ muslpkgs ? (import "${staticNix}/nixpkgs.nix").pkgsMusl
, nixpkgs ? import <nixpkgs> {}
, staticNix ? nixpkgs.fetchgit {
  url = "https://github.com/nh2/static-haskell-nix";
  sha256 = "0y97fvkjhvx17rmfdlymn4hwnq4r9nhf2r4m1s9fkh8gb8hfxp1s";
  rev = "dbce18f4808d27f6a51ce31585078b49c86bd2b5";
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
      muslpkgs.haskell.compiler.ghc882
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
