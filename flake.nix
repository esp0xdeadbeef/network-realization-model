{
  description = "Deterministic CPM to canonical network realization model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    network-realization-schema.url = "github:esp0xdeadbeef/network-realization-schema";
    network-realization-schema.inputs.nixpkgs.follows = "nixpkgs";
    # The schema pins a producer for its own cross-repository audit tests. Point
    # those at the same revisions this repository already uses instead of
    # resolving a second copy: one producer per lock, or "what the schema was
    # tested against" and "what this bundle was realized from" drift apart
    # silently inside one lock file.
    network-realization-schema.inputs.network-control-plane-model.follows = "network-control-plane-model";
    network-realization-schema.inputs.network-labs.follows = "network-labs";

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
      realBundleFor =
        system:
        model.realize {
          input = {
            kind = "network-control-plane-artifact";
            artifactIdentity = "real-cpm-${realTrace}";
            artifactDigest = builtins.hashString "sha256"
              (builtins.toJSON (realCpmFor system).control_plane_model);
            inherit ((realCpmFor system)) control_plane_model;
          };
          requestScope = {
            kind = "complete-artifact";
            identity = "real-${realTrace}";
          };
          rootLockIdentity = "network-realization-model-flake-lock";
          producerRevision = network-control-plane-model.rev or "network-control-plane-model";
        };
      testsPassFor = system:
        import ./tests/default.nix {
          inherit model schema;
          realCpm = realCpmFor system;
        };
      diagnosticCases = import ./tests/diagnostics.nix { inherit model schema; };
    in
    {

      # THE ENVIRONMENT THE TESTS NEED, DECLARED IN THE REPO-ROOT FLAKE.
      #
      # Every suite here shells out to nix, jq and git, and some use rg, ssh and
      # python3. Until this existed those came from the runner image plus ad-hoc
      # `curl`s in the workflow, so the environment was implicit: no derivation
      # described it, nothing could cache it coherently, and each job re-fetched the
      # same bytes.
      #
      # `nix develop` and `nix build .#devShells.<sys>.default` are the two consumers.
      # CI reads the PATH that `nix print-dev-env` reports and exports it, so the tools
      # a test runs are the ones declared here and nothing is installed outside it.
      #
      # Deliberately no `pkgs.nix`: CI installs its own Nix, and two versions evaluate
      # the same flake to different derivations -- which silently breaks every cache.
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            name = "network-tests";
            packages = [
              pkgs.git
              pkgs.jq
              pkgs.openssh
              pkgs.python3
              pkgs.ripgrep
              pkgs.zstd
            ];
          };
        }
      );

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

          # The bundle realized from a CPM the real producer compiled (see
          # `realBundleFor`). Kept separate from `example-bundle`, which wraps
          # the hand-written fixture in examples/cpm-result.nix.
          realBundleArtifact = pkgs.writeText "network-realization-real-bundle.json"
            (builtins.toJSON (realBundleFor system));
        in
        {
          default = artifact;
          example-bundle = artifact;
          real-bundle = realBundleArtifact;
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

          # A realized bundle must carry CANONICAL network content, not the
          # producer's data passed through under a validation wrapper.
          #
          # THIS CHECK CURRENTLY FAILS, on purpose. It is the guard for the
          # architectural defect that the whole renderer fleet inherits, and it
          # must not be made to pass by teaching this check to accept the raw
          # shape.
          #
          # Measured 2026-11-21, for a CPM compiled by the real producer from
          # row FS-540-HDS-010-SDS-010-SMS-020:
          #
          #   bundle.network.data keys: [ data, secretAuthorization,
          #     secretDeliveryRecords, secretPlaintextGuard, secretPolicyBoundary,
          #     secretReadiness, version ]
          #   bundle.network.data ? canonicalInterfaces   -> false
          #
          # So `network.data.data` is the producer's CPM data unchanged. There is
          # no canonicalized network content, which means every renderer's
          # "consume the validated canonical bundle" is, in substance, consuming
          # the CPM -- the wrapper adds validation, identity, provenance and
          # coverage, but no canonical semantics.
          #
          # Consequence downstream: a renderer can only be as strict as the raw
          # shape allows. network-renderer-openconfig demands canonical interface
          # identity (name + IANA type) and therefore fails; the others read the
          # same raw data and keep passing, so a missing or false canonical field
          # is invisible to them.
          canonical-bundle-content =
            let
              bundle = realBundleFor system;
              hasCanonical = bundle.network.data ? canonicalInterfaces;
              canonicalCount =
                if hasCanonical then builtins.length bundle.network.data.canonicalInterfaces else 0;
            in
            if hasCanonical && canonicalCount > 0 then
              pkgs.runCommand "network-realization-canonical-content" { } ''
                touch "$out"
              ''
            else
              pkgs.runCommand "network-realization-canonical-content" { } ''
                cat >&2 <<'MESSAGE'
            FAIL canonical-bundle-content: the realized bundle carries no canonical network content.

              bundle.network.data is the producer's CPM data unchanged (sites,
              secret projections, version). It has no canonicalInterfaces, no
              canonical routes, no canonical anything -- the bundle adds
              validation, identity, provenance and coverage around the raw CPM,
              but does not canonicalize it.

              That makes "renderers consume the validated canonical bundle" true
              only in the sense that they consume a validated copy of the CPM.
              A renderer can therefore only be as strict as the producer's raw
              shape allows:

                network-renderer-openconfig  requires canonical interface identity
                                             (name + IANA type) and FAILS
                nixos, containerlab,         read the same raw data and keep
                wireguard, nebula,           passing, so a missing or false
                access-endpoint              canonical field is invisible to them

              Fix: this repository must emit canonical network semantics (at
              minimum canonicalInterfaces with explicit identity and IANA type)
              and renderers must consume that instead of the producer's data.
              Not by relaxing the renderers -- the strict one is behaving
              correctly.
            MESSAGE
                exit 1
              '';
        }
        // diagnosticChecks
      );

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt-tree);
    };
}
