{ model, schema }:

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
in
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
assert rendererInput.controlPlaneEnvelope.control_plane_model == first.network.data;
true
