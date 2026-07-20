{
  description = "Deterministic CPM to canonical network realization model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    network-realization-schema.url = "github:esp0xdeadbeef/network-realization-schema";
    network-realization-schema.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      network-realization-schema,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = function: nixpkgs.lib.genAttrs systems function;
      schema = network-realization-schema.lib;
      model = import ./src/default.nix { inherit schema; };
      testsPass = import ./tests/default.nix { inherit model schema; };
      diagnosticCases = import ./tests/diagnostics.nix { inherit model schema; };
    in
    {
      lib = model;

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          bundle = model.realize {
            input = import ./examples/cpm-result.nix;
            requestScope = {
              kind = "complete-artifact";
              identity = "fixture-complete-artifact";
            };
            rootLockIdentity = "fixture-root-lock";
            producerRevision = "fixture-realization-model";
          };
          artifact = pkgs.writeText "network-realization-bundle.json" (builtins.toJSON bundle);
        in
        {
          default = artifact;
          example-bundle = artifact;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          diagnosticChecks = nixpkgs.lib.mapAttrs' (
            name: testCase:
            nixpkgs.lib.nameValuePair "diagnostic-${name}" (
              pkgs.runCommand "network-realization-model-diagnostic-${name}" { } ''
                export HOME="$TMPDIR/home"
                export NIX_CONFIG='flake-registry ='
                mkdir -p "$HOME"
                if ${pkgs.nix}/bin/nix-instantiate \
                  --eval --strict \
                  --arg schema 'import ${network-realization-schema}/lib/default.nix' \
                  --arg model 'import ${self}/src/default.nix { schema = import ${network-realization-schema}/lib/default.nix; }' \
                  --attr ${name}.value \
                  ${self}/tests/diagnostics.nix >stdout 2>stderr
                then
                  echo "negative case ${name} unexpectedly succeeded" >&2
                  exit 1
                fi
                if ! grep -F -- ${builtins.toJSON testCase.expected} stderr
                then
                  echo "negative case ${name} emitted the wrong diagnostic" >&2
                  cat stderr >&2
                  exit 1
                fi
                touch "$out"
              ''
            )
          ) diagnosticCases;
        in
        assert testsPass;
        {
          realization-model = pkgs.runCommand "network-realization-model" { } ''
            mkdir -p "$out"
            cp "${self.packages.${system}.example-bundle}" "$out/bundle.json"
          '';
        }
        // diagnosticChecks
      );

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt-tree);
    };
}
