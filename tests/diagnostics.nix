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
  candidate = model.makeCandidate args;
  rehash =
    value:
    (builtins.removeAttrs value [ "bundleIdentity" ])
    // {
      bundleIdentity = schema.computeBundleIdentity (builtins.removeAttrs value [ "bundleIdentity" ]);
    };
  missingCoverage = rehash (
    candidate
    // {
      upstreamCoverage = builtins.tail candidate.upstreamCoverage;
    }
  );
  duplicateCoverage = rehash (
    candidate
    // {
      upstreamCoverage = candidate.upstreamCoverage ++ [ (builtins.head candidate.upstreamCoverage) ];
    }
  );
  invented = rehash (
    candidate
    // {
      network.data = candidate.network.data // {
        inventedFirewallAllow = true;
      };
    }
  );
  replaceFirstCoverage =
    transformation:
    rehash (
      candidate
      // {
        upstreamCoverage = [
          (transformation (builtins.head candidate.upstreamCoverage))
        ]
        ++ builtins.tail candidate.upstreamCoverage;
      }
    );
  badRule = replaceFirstCoverage (row: row // { transformationRule = "unknown-rule"; });
  badProvenance = replaceFirstCoverage (row: builtins.removeAttrs row [ "sourceArtifactIdentity" ]);
  protectedMaterial = rehash (
    candidate
    // {
      protectedReferences = [
        {
          reference = "/run/secrets/example";
          classification = "protected";
          value = "must-not-appear";
        }
      ];
    }
  );
  wrongSchema = rehash (candidate // { schemaRevision = "network-realization/unknown"; });
  scopeEscape = rehash (
    candidate
    // {
      requestScope = {
        kind = "source-prefixes";
        identity = "interfaces-only";
        sourcePrefixes = [ "/control_plane_model/data/example/site/runtimeTargets/router/interfaces" ];
      };
    }
  );
  released = model.realize args;
  bindingBase = {
    kind = schema.schema.platformBinding.kind;
    schemaRevision = schema.schema.platformBinding.revision;
    bundleIdentity = released.bundleIdentity;
    target = "nixos";
    requestScope = released.requestScope;
    categories = { };
    provenance = {
      producer = "fixture";
      producerRevision = "fixture";
    };
  };
  bindingWithIdentity = bindingBase // {
    bindingIdentity = schema.computeBindingIdentity bindingBase;
  };
  releasedBinding = bindingWithIdentity // {
    validation = schema.validatePlatformBinding bindingWithIdentity;
  };
in
{
  requiredAuthorityMissing = {
    expected = "NR_REQUIRED_AUTHORITY_MISSING: /artifactIdentity:";
    value = model.makeCandidate (
      args
      // {
        input = builtins.removeAttrs input [ "artifactIdentity" ];
      }
    );
  };
  authorityAmbiguous = {
    expected = "NR_AUTHORITY_AMBIGUOUS: /authorityConflicts:";
    value = model.validateProducerAccounting {
      input = input // {
        authorityConflicts = [
          {
            canonicalPath = "/network/data/data/example/site/runtimeTargets/router/interfaces/lan/mtu";
            sources = [
              "/a"
              "/b"
            ];
          }
        ];
      };
      inherit candidate;
    };
  };
  inventedSemantic = {
    expected = "NR_REALIZATION_INVENTED_SEMANTIC: /network/data:";
    value = model.validateProducerAccounting {
      inherit input;
      candidate = invented;
    };
  };
  producerUnaccounted = {
    expected = "NR_UPSTREAM_PATH_UNACCOUNTED:";
    value = model.validateProducerAccounting {
      inherit input;
      candidate = missingCoverage;
    };
  };
  coverageMissing = {
    expected = "NR_UPSTREAM_COVERAGE_MISSING:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = missingCoverage;
    };
  };
  coverageDuplicate = {
    expected = "NR_UPSTREAM_COVERAGE_DUPLICATE:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = duplicateCoverage;
    };
  };
  unknownRule = {
    expected = "NR_UPSTREAM_RULE_UNKNOWN:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = badRule;
    };
  };
  provenanceIncomplete = {
    expected = "NR_PROVENANCE_INCOMPLETE:";
    value = model.validateProducerAccounting {
      inherit input;
      candidate = badProvenance;
    };
  };
  protectedMaterial = {
    expected = "NR_PROTECTED_VALUE_EXPOSED:";
    value = model.release {
      inherit input;
      candidate = protectedMaterial;
    };
  };
  nondeterministic = {
    expected = "NR_NONDETERMINISTIC_BUNDLE: /bundleIdentity:";
    value = model.assertDeterministic {
      first = candidate;
      second = candidate // {
        bundleIdentity = "different";
      };
    };
  };
  scopeEscape = {
    expected = "NR_SCOPE_ESCAPE:";
    value = model.validateScope scopeEscape;
  };
  schemaValidationFailed = {
    expected = "NR_SCHEMA_VALIDATION_FAILED: /schemaRevision: NR_SCHEMA_UNKNOWN";
    value = model.release {
      inherit input;
      candidate = wrongSchema;
    };
  };
  rendererBundleUnvalidated = {
    expected = "NR_RENDERER_BUNDLE_UNVALIDATED: /validation:";
    value = model.validateRendererInput {
      bundle = builtins.removeAttrs released [ "validation" ];
      expectedTarget = "nixos";
    };
  };
  rendererBindingUnvalidated = {
    expected = "NR_PLATFORM_BINDING_UNVALIDATED: /validation:";
    value = model.validateRendererInput {
      bundle = released;
      platformBinding = bindingWithIdentity;
      expectedTarget = "nixos";
    };
  };
  rendererBindingTargetMismatch = {
    expected = "NR_PLATFORM_BINDING_TARGET_MISMATCH: /target:";
    value = model.validateRendererInput {
      bundle = released;
      platformBinding = releasedBinding;
      expectedTarget = "clab";
    };
  };
}
