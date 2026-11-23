{ model, schema, realCpm }:

let
  input = import ../examples/cpm-result.nix;
  args = {
    inherit input;
    requestScope = {
      kind = "complete-artifact";
      identity = "fixture-complete-artifact";
    };
    rootLockIdentity = "fixture-root-lock";
    producerRevision = "fixture-realization-model";
  };
  first = model.realize args;

  # The production path: a CPM compiled by the real producer from a real intent
  # in network-labs. Everything above uses examples/cpm-result.nix, which is
  # hand-written -- so without this, nothing in this repository's tests has ever
  # been run against a CPM that a producer actually emits.
  #
  # Measured 2026-11-21: this realizes cleanly, and that is exactly why the gap
  # went unseen -- `realize` does not require any particular optional collection,
  # so a bundle can be produced and validated from a CPM that no peer renderer
  # can map (the CPM publishes no `canonicalInterfaces`). The producer-boundary
  # assertion therefore has to live where the field is consumed; see
  # network-renderer-openconfig's `canonical-renderer-input` check.
  realInput = {
    kind = "network-control-plane-artifact";
    artifactIdentity = "real-cpm-single-wan-uplink-static-egress";
    artifactDigest = builtins.hashString "sha256" (builtins.toJSON realCpm.control_plane_model);
    inherit (realCpm) control_plane_model;
  };
  realArgs = {
    input = realInput;
    requestScope = {
      kind = "complete-artifact";
      identity = "real-cpm-complete-artifact";
    };
    rootLockIdentity = "real-cpm-root-lock";
    producerRevision = "network-control-plane-model";
  };
  realFirst = model.realize realArgs;
  realSecond = model.realize realArgs;
  realCoverage = model.validateUpstreamCoverage {
    input = realInput;
    candidate = realFirst;
  };
  second = model.realize args;
  bindingBase = {
    kind = schema.schema.platformBinding.kind;
    schemaRevision = schema.schema.platformBinding.revision;
    bundleIdentity = first.bundleIdentity;
    target = "openconfig";
    requestScope = first.requestScope;
    categories = {
      interfaceIdentity.router-lan.canonicalPath = "/network/data/data/example/site/runtimeTargets/router/interfaces/lan";
      deployment = { };
      secretDelivery = { };
      lifecycle = { };
      backend.yangModel = "openconfig-interfaces";
    };
    provenance = {
      producer = "network-labs";
      producerRevision = "fixture";
      sourceIdentity = "fixture-binding";
    };
  };
  bindingWithIdentity = bindingBase // {
    bindingIdentity = schema.computeBindingIdentity bindingBase;
  };
  binding = bindingWithIdentity // {
    validation = schema.validatePlatformBinding bindingWithIdentity;
  };
  coverage = model.validateUpstreamCoverage {
    inherit input;
    candidate = first;
  };
  bindingValidation = model.validatePlatformBindingAgainstBundle {
    bundle = first;
    inherit binding;
    expectedTarget = "openconfig";
  };
  rendererInput = model.validateRendererInput {
    bundle = first;
    platformBinding = binding;
    expectedTarget = "openconfig";
  };
  realRendererInput = model.validateRendererInput {
    bundle = realFirst;
    expectedTarget = "nixos";
  };

  # FS-161: protected references are opaque runtime references. The producer
  # projects every /run/secrets leaf the canonical content names, and unions
  # any explicitly declared reference, so a bundle can never omit one of its own
  # protected references.
  secretControlPlaneModel = input.control_plane_model // {
    data.example.site.runtimeTargets.router.delegatedPrefix = {
      sourceFile = "/run/secrets/example-tenant-prefix";
    };
    data.example.site.runtimeTargets.router.publicIngress = [
      {
        sourceFile = "/run/secrets/example-provider-prefix";
        family = 6;
      }
    ];
  };
  secretInput = {
    kind = "network-control-plane-artifact";
    artifactIdentity = "fixture-cpm-secret-v1";
    artifactDigest = builtins.hashString "sha256" (builtins.toJSON secretControlPlaneModel);
    control_plane_model = secretControlPlaneModel;
  };
  secretBundle = model.realize {
    input = secretInput;
    requestScope = {
      kind = "complete-artifact";
      identity = "fixture-secret-artifact";
    };
    rootLockIdentity = "fixture-root-lock";
    producerRevision = "fixture-realization-model";
    protectedReferences = [
      {
        reference = "/run/secrets/example-declared-only";
        classification = "protected";
      }
    ];
  };
  secretReferences = map (record: record.reference) secretBundle.protectedReferences;

# A platform binding may reference a protected path the bundle declares ...
secretBindingBase = {
  kind = schema.schema.platformBinding.kind;
  schemaRevision = schema.schema.platformBinding.revision;
  bundleIdentity = secretBundle.bundleIdentity;
  target = "nixos";
  requestScope = secretBundle.requestScope;
  categories = {
    interfaceIdentity = { };
    deployment = { };
    secretDelivery.tenantPrefix.reference = "/run/secrets/example-tenant-prefix";
    lifecycle = { };
    backend = { };
  };
  provenance = {
    producer = "network-fixture";
    producerRevision = "fixture";
    sourceIdentity = "fixture-binding";
  };
};
withSecretBindingIdentity =
  binding:
  binding
  // {
    bindingIdentity = schema.computeBindingIdentity (
      builtins.removeAttrs binding [ "bindingIdentity" ]
    );
  };
declaredSecretBinding =
  withSecretBindingIdentity secretBindingBase
  // {
    validation = schema.validatePlatformBinding (withSecretBindingIdentity secretBindingBase);
  };
undeclaredSecretBinding =
  withSecretBindingIdentity (
    secretBindingBase
    // {
      categories = secretBindingBase.categories // {
        secretDelivery.undeclared.reference = "/run/secrets/not-in-the-bundle";
      };
    }
  )
  // {
    validation = schema.validatePlatformBinding (
      withSecretBindingIdentity (
        secretBindingBase
        // {
          categories = secretBindingBase.categories // {
            secretDelivery.undeclared.reference = "/run/secrets/not-in-the-bundle";
          };
        }
      )
    );
  };
in
assert realFirst.validation.valid;
assert realFirst.validation.artifactIdentity == realFirst.bundleIdentity;
assert model.assertDeterministic { first = realFirst; second = realSecond; };
assert realCoverage.sourceCount == realCoverage.destinationCount;
assert schema.validateBundle first != { };
assert first.validation.valid;
assert first.validation.artifactIdentity == first.bundleIdentity;
assert first.validation.schemaSetIdentity == schema.schemaSetIdentity;
assert model.assertDeterministic { inherit first second; };
assert coverage.sourceCount == coverage.destinationCount;
assert coverage.sourceCount == coverage.coverageCount;
assert bindingValidation.valid;
assert rendererInput.bundleIdentity == first.bundleIdentity;
assert rendererInput.bindingIdentity == binding.bindingIdentity;
assert rendererInput.validatedPlatformBinding == binding;
assert rendererInput.controlPlaneEnvelope.control_plane_model == first.network.data;
# RR_RAW_CPM_INPUT: the bundle must carry the producer's canonical collections
# itself, so a renderer can map canonical objects without reading the model the
# bundle wraps. `realInput` is a real producer CPM, and that producer publishes
# canonicalInterfaces and canonicalRoutes.
assert builtins.isAttrs realFirst.canonical;
assert (realFirst.canonical.canonicalInterfaces or null) == realCpm.control_plane_model.canonicalInterfaces;
assert (realFirst.canonical.canonicalRoutes or null) == realCpm.control_plane_model.canonicalRoutes;
assert builtins.length realFirst.canonical.canonicalInterfaces > 0;
assert builtins.length realFirst.canonical.canonicalRoutes > 0;
# and the renderer boundary hands it over by that name
assert realRendererInput.canonical.canonicalInterfaces == realCpm.control_plane_model.canonicalInterfaces;
# A producer that hands over the BUILD RESULT (which wraps the envelope) must
# still get its canonical collections projected. Measured 2026-11-22: the nixos
# host pipeline did exactly that, `canonical` projected to `{ }`, and every
# renderer that maps canonical content had nothing to map.
assert
  (model.canonicalFor { inherit (realCpm) control_plane_model; }).canonicalInterfaces
  == (model.canonicalFor realCpm).canonicalInterfaces;
assert builtins.length (model.canonicalFor realCpm).canonicalRoutes > 0;
# The carrier must be unambiguous. A producer that publishes canonical
# collections at BOTH the top level and in the wrapped envelope, with different
# values, is making two contradictory statements, and picking one here would
# choose what every renderer sees. Fail closed instead.
assert
  let
    probe = value: { canonicalInterfaces = [ { marker = value; } ]; };
    accepted = v: (builtins.tryEval (builtins.deepSeq (model.canonicalFor v) true)).success;
  in
  accepted (probe 1)
  && accepted { control_plane_model = probe 1; }
  && accepted ((probe 1) // { control_plane_model = probe 1; })
  && !(accepted ((probe 1) // { control_plane_model = probe 2; }));
# The hand-written fixture publishes canonicalInterfaces too, and the bundle
# carries it unchanged -- projection, not invention.
assert first.canonical.canonicalInterfaces == input.control_plane_model.canonicalInterfaces;
assert secretBundle.validation.valid;
assert builtins.elem "/run/secrets/example-tenant-prefix" secretReferences;
assert builtins.elem "/run/secrets/example-provider-prefix" secretReferences;
assert builtins.elem "/run/secrets/example-declared-only" secretReferences;
assert builtins.length secretReferences == 3;
assert (model.validatePlatformBindingAgainstBundle {
  bundle = secretBundle;
  binding = declaredSecretBinding;
  expectedTarget = "nixos";
}).valid;
assert
  !(builtins.tryEval (
    builtins.deepSeq
      (model.validatePlatformBindingAgainstBundle {
        bundle = secretBundle;
        binding = undeclaredSecretBinding;
        expectedTarget = "nixos";
      })
      true
  )).success;
true
