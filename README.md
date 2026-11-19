# network-realization-model

`network-realization-model` is the deterministic transformation stage between
`network-control-plane-model` (CPM) and every `network-renderer-*` repository.
It produces the validated canonical realization bundle that is the sole
network-semantic input to renderers.

The implementation is Nix-native. It emits deterministic canonical bundles,
separates producer accounting from the independent upstream-coverage gate, and
validates normalized platform-binding references against exact canonical
JSON-pointer paths.

## Position in the architecture

```text
network-compiler
      |
      v
network-forwarding-model
      |
      v
network-control-plane-model
      |
      v
network-realization-model ---- validates against ----> network-realization-schema
      |
      v
validated canonical realization bundle
      |
      +--> network-renderer-nixos
      +--> network-renderer-containerlab-linux-backend
      +--> network-renderer-wireguard
      +--> network-renderer-nebula
      +--> network-renderer-openconfig
      `--> other peer network-renderer-* targets
```

Every renderer consumes the same validated bundle. When target mechanics
require them, a renderer may additionally consume one normalized, validated
platform-binding bundle. That bundle has one schema and one identity while
containing multiple permitted categories: interface identity, deployment,
secret delivery, lifecycle, backend or package selection, and provenance. It
may map canonical objects to platform mechanics, but it may not create network
meaning or stack uncontrolled sidecars.

## Responsibilities

This repository:

- consumes scoped CPM output and authorized realization facts;
- concretizes explicit upstream meaning into deterministic canonical values;
- validates the candidate against the pinned `network-realization-schema`;
- emits exact source-path provenance with versioned transformation rules;
- reports upstream realization coverage and fails on unclassified required
  semantics;
- releases a digest-addressed canonical bundle only after its required checks
  pass.

Realization may make declared meaning executable. It must not reinterpret,
weaken, widen, reclassify, replace, or repair upstream intent or authority. It
must not invent missing topology, reachability, addressing, routing, DNS,
NAT/NAT66, firewall, exposure, or trust behavior.

Renderer-consumption coverage and rendered-output coverage remain the
responsibility of each renderer; they are separate from this repository's
upstream realization coverage.

`lib.validateRendererInput` is the common renderer-entry boundary. It requires
the schema- and digest-bound bundle release record, validates the optional
normalized platform-binding bundle against the exact bundle, scope, and target,
and returns the canonical semantic model plus an internal CPM compatibility
envelope. The compatibility envelope is not a public renderer input and does
not authorize raw CPM entry.

## Known gap: CPM sibling aggregates are not carried in the bundle

`bundle.network` is exactly the CPM's `control_plane_model` attribute. The CPM
also emits sibling aggregates beside it -- `endpointAssignment`,
`deploymentHosts` and `endpointInventory` -- and at least one of those is the
only place a fact is recorded.

`network-control-plane-model` `src/main.nix` builds a top-level
`endpointAssignment` from `cpm/hat-endpoint-assignment.nix`, derived from the
inventory's `deployment.hosts`. That aggregate is the only place an endpoint is
marked `role = "management"`; the per-site `endpointAssignment` records produced
by `cpm/Site/build-data/endpoint-assignment.nix` carry `bridge`, `tenant` and the
address fields but no `role`.

`network-renderer-access-endpoint-nixos` enforces
`FS-725-HDS-020-SDS-010-SMS-010: EMPTY_MANAGEMENT_ENDPOINT_INVENTORY` when a
`mgmt` bridge is declared but no endpoint assignment on it is marked management.
Because the bundle drops the aggregate, that guard cannot be satisfied for any
input whose management fact lives only there, and the host module is
un-evaluatable: `FS-720-HDS-010-SDS-020-SMS-020` fails inside AP-1 with that
diagnostic even though the CPM output does record the role (verified: 3
assignments with `role = "management"` on `mgmt` for the
`emulated-isp-residential-testnet` fixture).

This is not fixable inside a renderer or a test. The options are:

1. carry the sibling aggregates in `network.data` (a schema change: the bundle
   shape, `computeBundleIdentity` and every digest-bound consumer move together);
2. have the CPM record `role` on the per-site `endpointAssignment` as well, so
   the fact survives without widening the bundle; or
3. re-derive the management fact from `deploymentHosts` in whoever consumes it,
   which needs the aggregate carried anyway.

Whichever is chosen, it is a change to the CPM/bundle contract and must be made
with the owning repositories' schema tests in the same commit.

## Repository layout

```text
src/          canonical bundle construction, normalization, and validation
tests/        focused positive, negative, determinism, and coverage checks
examples/     small CPM-to-bundle examples and expected diagnostics
flake.nix     pinned build, check, and development entry points
```

The implementation follows the controlled design and construction chain. Gaps
in an upstream or schema contract must fail visibly and be fixed in the owning
layer rather than hidden in local defaults.

## Versioning

This project primarily supports my own infrastructure. Consumers should pin an
exact revision. Backward compatibility is not guaranteed unless a compatibility
boundary is explicitly specified and tested.
