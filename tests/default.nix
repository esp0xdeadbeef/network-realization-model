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
