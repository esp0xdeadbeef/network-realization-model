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
    let
      stripped = builtins.removeAttrs value [
        "bundleIdentity"
        "coverageIdentity"
      ];
      withCoverage = stripped // { coverageIdentity = schema.computeCoverageIdentity stripped; };
    in
    withCoverage // { bundleIdentity = schema.computeBundleIdentity withCoverage; };
  # The accounting is recomputed, so the only way to make a path genuinely
  # unaccounted is to declare invariants that cannot classify it.
  missingCoverage = rehash (
    candidate
    // {
      coverageInvariants = builtins.removeAttrs candidate.coverageInvariants [ "classification" ];
    }
  );
  duplicateCoverage = rehash (
    candidate
    // {
      upstreamCoverage =
        model.coverageRowsFor candidate ++ [ (builtins.head (model.coverageRowsFor candidate)) ];
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
  # With the accounting derived from bundle network content, the injected fault
  # moves from a per-row field to the declared invariants that decide it.
  replaceFirstCoverage =
    transformation:
    rehash (
      candidate
      // {
        upstreamCoverage = [ (transformation (builtins.head (model.coverageRowsFor candidate))) ]
          ++ builtins.tail (model.coverageRowsFor candidate);
      }
    );
  badRule = rehash (
    candidate
    // {
      coverageInvariants = candidate.coverageInvariants // {
        transformationRule = "unknown-rule";
      };
    }
  );
  badProvenance = rehash (
    candidate
    // {
      coverageInvariants = builtins.removeAttrs candidate.coverageInvariants [ "transformationRule" ];
    }
  );
  # Destinations are derived from the source path, so an invalid destination is
  # produced by giving the bundle network content that lies outside the CPM
  # prefix the destination rule maps from.
  badDestination = rehash (
    candidate
    // {
      network.data = {
        outsideControlPlane = [ 1 ];
      }
      // candidate.network.data;
    }
  );
  orphanPath = rehash (
    candidate
    // {
      network.data = candidate.network.data // {
        orphanField = "orphan-value";
      };
    }
  );
  unsupportedRequired = rehash (
    candidate
    // {
      coverageInvariants = candidate.coverageInvariants // {
        classification = "rejected-unsupported";
      };
    }
  );
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
  # A CPM path the bundle does not account for. With derived accounting the
  # fault is injected on the source side (an extra CPM leaf) rather than on a
  # delivered row, which no longer exists.
  # A CPM path the bundle does not account for. Derived accounting recomputes
  # from the CPM, so the fault is injected on the source side: the CPM gains a
  # leaf that the declared accounting cannot classify.
  producerUnaccounted = {
    expected = "NR_UPSTREAM_PATH_UNACCOUNTED:";
    value = model.validateProducerAccounting {
      input = input // {
        control_plane_model = input.control_plane_model // {
          extraUnaccountedLeaf = "x";
        };
      };
      candidate = candidate;
    };
  };
  coverageMissing = {
    expected = "NR_COVERAGE_INVALID:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = missingCoverage;
    };
  };
  # Duplicate detection now lives where it can actually be observed: the
  # accounting is recomputed from bundle network content, so a duplicate is
  # caught by the schema's expanded-vs-recomputed comparison rather than by the
  # producer's recomputation.
  coverageDuplicate = {
    expected = "NR_COVERAGE_INVALID:";
    value = schema.validateBundle duplicateCoverage;
  };
  unknownRule = {
    expected = "NR_UPSTREAM_RULE_UNKNOWN:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = badRule;
    };
  };
  destinationInvalid = {
    expected = "NR_UPSTREAM_DESTINATION_INVALID:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = badDestination;
    };
  };
  # With the accounting derived from network content, a canonical path that has
  # no CPM authority is rejected as an unaccounted destination before it can
  # become an orphan. Fail-closed either way; this names the first observable
  # failure.
  orphanCanonical = {
    expected = "NR_UPSTREAM_DESTINATION_INVALID:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = orphanPath;
    };
  };
  unsupportedRequirement = {
    expected = "NR_UNSUPPORTED_REQUIRED_SEMANTIC:";
    value = model.validateUpstreamCoverage {
      inherit input;
      candidate = unsupportedRequired;
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
