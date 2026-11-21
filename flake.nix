{
  description = "Deterministic CPM to canonical network realization model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    network-realization-schema.url = "github:esp0xdeadbeef/network-realization-schema";
    network-realization-schema.inputs.nixpkgs.follows = "nixpkgs";

    # A producer, so the tests can realise a REAL CPM and not only the
    # hand-written one in examples/cpm-result.nix. This repository has no
    # dependency cycle to fear: network-control-plane-model depends on
    # network-forwarding-model and network-labs, neither of which depends on
    # this one. See the note at the top of examples/cpm-result.nix for what
    # went wrong while these inputs were absent.
    network-control-plane-model.url = "github:esp0xdeadbeef/network-control-plane-model";
    network-control-plane-model.inputs.nixpkgs.follows = "nixpkgs";
    network-control-plane-model.inputs.network-labs.follows = "network-labs";
    network-labs.url = "github:esp0xdeadbeef/network-labs";
    network-labs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      network-realization-schema,
      network-control-plane-model,
      network-labs,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = function: nixpkgs.lib.genAttrs systems function;
      schema = network-realization-schema.lib;
      model = import ./src/default.nix { inherit schema; };
      # A CPM compiled by the real producer from a real intent, per system.
      #
      # The row and inventory follow the same convention the renderer tests use
      # (network-renderer-nixos: `network-labs/GAMP/SMT/<row>/intent.nix` with
      # `inventory-nixos.nix`; containerlab: the same row with
      # `inventory-clab.nix`). This repository is target-agnostic, so it takes
      # the NixOS inventory of the shared row -- the bundle it validates is then
      # the same identity path a peer renderer consumes, which is the whole
      # point of validating one canonical bundle for many targets.
      #
      # No path is hardcoded: the row and the inventory are the only things
      # named, and they are resolved against the network-labs flake input.
      realTrace = "FS-540-HDS-010-SDS-010-SMS-020";
      realRow = network-labs + "/GAMP/SMT/${realTrace}";
      realCpmFor =
        system:
        network-control-plane-model.libBySystem.${system}.compileAndBuildFromPaths {
          inputPath = "${realRow}/intent.nix";
          inventoryPath = "${realRow}/inventory-nixos.nix";
        };
      testsPassFor = system:
        import ./tests/default.nix {
          inherit model schema;
          realCpm = realCpmFor system;
        };
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
        assert testsPassFor system;
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
