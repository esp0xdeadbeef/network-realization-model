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

## Planned repository layout

```text
src/          canonical bundle construction, normalization, and validation
tests/        focused positive, negative, determinism, and coverage checks
examples/     small CPM-to-bundle examples and expected diagnostics
flake.nix     pinned build, check, and development entry points
```

The exact implementation is added through the controlled design and
construction chain. Gaps in an upstream or schema contract must fail visibly
and be fixed in the owning layer rather than hidden in local defaults.

## Versioning

This project primarily supports my own infrastructure. Consumers should pin an
exact revision. Backward compatibility is not guaranteed unless a compatibility
boundary is explicitly specified and tested.
