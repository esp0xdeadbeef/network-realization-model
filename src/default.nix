{ schema }:

let
  fail =
    code: path: detail:
    throw "${code}: ${path}: ${detail}";

  nonEmptyString = value: builtins.isString value && value != "";

  requireAttrs =
    code: path: value:
    if builtins.isAttrs value then value else fail code path "expected attribute set";

  requireList =
    code: path: value:
    if builtins.isList value then value else fail code path "expected list";

  requireString =
    code: path: value:
    if nonEmptyString value then value else fail code path "expected non-empty string";

  unique =
    values:
    builtins.attrNames (
      builtins.listToAttrs (
        map (value: {
          name = value;
          value = true;
        }) values
      )
    );

  duplicates =
    values:
    builtins.filter (value: builtins.length (builtins.filter (item: item == value) values) > 1) (
      unique values
    );

  difference = left: right: builtins.filter (value: !(builtins.elem value right)) left;

  hasPrefix =
    prefix: value:
    builtins.stringLength value >= builtins.stringLength prefix
    && builtins.substring 0 (builtins.stringLength prefix) value == prefix;

  destinationFor =
    sourcePath:
    let
      prefix = "/control_plane_model";
    in
    if hasPrefix prefix sourcePath then
      "/network/data${
        builtins.substring (builtins.stringLength prefix) (
          builtins.stringLength sourcePath - builtins.stringLength prefix
        ) sourcePath
      }"
    else
      fail "NR_UPSTREAM_DESTINATION_INVALID" sourcePath "source path is outside control_plane_model";

  cpmFrom =
    input:
    let
      artifact = requireAttrs "NR_REQUIRED_AUTHORITY_MISSING" "/" input;
    in
    requireAttrs "NR_REQUIRED_AUTHORITY_MISSING" "/control_plane_model" (
      artifact.control_plane_model or null
    );

  sourceIdentityFrom =
    input:
    requireString "NR_REQUIRED_AUTHORITY_MISSING" "/artifactIdentity" (input.artifactIdentity or null);

  sourceDigestFor = cpm: builtins.hashString "sha256" (builtins.toJSON cpm);

  sourceRecordsFor =
    cpm:
    schema.paths.leafRecords {
      value = cpm;
      rootPath = "/control_plane_model";
    };

  canonicalRecordsFor =
    candidate:
    schema.paths.leafRecords {
      value = candidate.network.data;
      rootPath = "/network/data";
    };

  coverageFor =
    sourceIdentity: sourceRecords:
    map (record: {
      sourcePath = record.path;
      destinationPath = destinationFor record.path;
      classification = "realized";
      transformationRule = "cpm-identity-v1";
      sourceArtifactIdentity = sourceIdentity;
    }) sourceRecords;

  collectCanonicalReferences =
    value:
    if builtins.isAttrs value then
      (
        if value ? canonicalPath && nonEmptyString value.canonicalPath then [ value.canonicalPath ] else [ ]
      )
      ++ builtins.concatLists (
        map (name: collectCanonicalReferences value.${name}) (builtins.attrNames value)
      )
    else if builtins.isList value then
      builtins.concatLists (map collectCanonicalReferences value)
    else
      [ ];

  validateProducerAccounting =
    { input, candidate }:
    let
      cpm = cpmFrom input;
      sourceIdentity = sourceIdentityFrom input;
      conflicts = requireList "NR_AUTHORITY_AMBIGUOUS" "/authorityConflicts" (
        input.authorityConflicts or [ ]
      );
      sourcePaths = map (record: record.path) (sourceRecordsFor cpm);
      coverage = requireList "NR_UPSTREAM_PATH_UNACCOUNTED" "/upstreamCoverage" (
        candidate.upstreamCoverage or null
      );
      coveragePaths = map (row: row.sourcePath or "") coverage;
      missing = difference sourcePaths coveragePaths;
      incompleteProvenance = builtins.filter (
        row:
        (row.sourceArtifactIdentity or null) != sourceIdentity
        || (row.transformationRule or null) != "cpm-identity-v1"
      ) coverage;
      _conflicts =
        if conflicts == [ ] then
          true
        else
          fail "NR_AUTHORITY_AMBIGUOUS" "/authorityConflicts" (builtins.toJSON conflicts);
      _coverage =
        if missing == [ ] then
          true
        else
          fail "NR_UPSTREAM_PATH_UNACCOUNTED" (builtins.head missing)
            "no transformation or rejection classification";
      _network =
        if candidate.network.data == cpm then
          true
        else
          fail "NR_REALIZATION_INVENTED_SEMANTIC" "/network/data"
            "canonical semantics differ from CPM authority";
      _sourceIdentity =
        if (candidate.sources.cpm.identity or null) == sourceIdentity then
          true
        else
          fail "NR_PROVENANCE_INCOMPLETE" "/sources/cpm/identity" "source artifact identity mismatch";
      _sourceDigest =
        if (candidate.sources.cpm.digest or null) == sourceDigestFor cpm then
          true
        else
          fail "NR_PROVENANCE_INCOMPLETE" "/sources/cpm/digest" "source artifact digest mismatch";
      _provenance =
        if incompleteProvenance == [ ] then
          true
        else
          fail "NR_PROVENANCE_INCOMPLETE" "/upstreamCoverage"
            "source or transformation identity is incomplete";
    in
    builtins.deepSeq [ _conflicts _coverage _network _sourceIdentity _sourceDigest _provenance ] true;

  validateUpstreamCoverage =
    { input, candidate }:
    let
      cpm = cpmFrom input;
      sourceIdentity = sourceIdentityFrom input;
      sourcePaths = map (record: record.path) (sourceRecordsFor cpm);
      canonicalPaths = map (record: record.path) (canonicalRecordsFor candidate);
      coverage = requireList "NR_UPSTREAM_COVERAGE_MISSING" "/upstreamCoverage" (
        candidate.upstreamCoverage or null
      );
      coverageSourcePaths = map (row: row.sourcePath or "") coverage;
      coverageDestinationPaths = map (row: row.destinationPath or "") coverage;
      duplicateSources = duplicates coverageSourcePaths;
      missingSources = difference sourcePaths coverageSourcePaths;
      unexpectedSources = difference coverageSourcePaths sourcePaths;
      missingDestinations = difference canonicalPaths coverageDestinationPaths;
      invalidDestinations = difference coverageDestinationPaths canonicalPaths;
      unknownRules = builtins.filter (
        row: (row.transformationRule or null) != "cpm-identity-v1"
      ) coverage;
      wrongProvenance = builtins.filter (
        row: (row.sourceArtifactIdentity or null) != sourceIdentity
      ) coverage;
      unsupportedRequired = builtins.filter (
        row: (row.classification or null) == "rejected-unsupported"
      ) coverage;
      _duplicates =
        if duplicateSources == [ ] then
          true
        else
          fail "NR_UPSTREAM_COVERAGE_DUPLICATE" (builtins.head duplicateSources) "multiple classifications";
      _missing =
        if missingSources == [ ] then
          true
        else
          fail "NR_UPSTREAM_COVERAGE_MISSING" (builtins.head missingSources) "classification absent";
      _unexpected =
        if unexpectedSources == [ ] then
          true
        else
          fail "NR_UPSTREAM_DESTINATION_INVALID" (builtins.head unexpectedSources) "source path is absent";
      _destination =
        if invalidDestinations == [ ] then
          true
        else
          fail "NR_UPSTREAM_DESTINATION_INVALID" (builtins.head invalidDestinations)
            "destination path is absent";
      _orphan =
        if missingDestinations == [ ] then
          true
        else
          fail "NR_ORPHAN_CANONICAL_PATH" (builtins.head missingDestinations) "no upstream source";
      _rule =
        if unknownRules == [ ] then
          true
        else
          fail "NR_UPSTREAM_RULE_UNKNOWN" ((builtins.head unknownRules).sourcePath or "/upstreamCoverage"
          ) "unknown transformation rule";
      _provenance =
        if wrongProvenance == [ ] then
          true
        else
          fail "NR_PROVENANCE_INCOMPLETE" ((builtins.head wrongProvenance).sourcePath or "/upstreamCoverage"
          ) "source identity mismatch";
      _unsupported =
        if unsupportedRequired == [ ] then
          true
        else
          fail "NR_UNSUPPORTED_REQUIRED_SEMANTIC" ((builtins.head unsupportedRequired).sourcePath
            or "/upstreamCoverage"
          ) "required semantic was rejected";
    in
    builtins.deepSeq
      [
        _duplicates
        _missing
        _unexpected
        _destination
        _orphan
        _rule
        _provenance
        _unsupported
      ]
      {
        valid = true;
        sourceCount = builtins.length sourcePaths;
        destinationCount = builtins.length canonicalPaths;
        coverageCount = builtins.length coverage;
      };

  validateScope =
    candidate:
    let
      scope = requireAttrs "NR_SCOPE_ESCAPE" "/requestScope" (candidate.requestScope or null);
      prefixes = scope.sourcePrefixes or [ ];
      paths = map (row: row.sourcePath or "") candidate.upstreamCoverage;
      escaped =
        if (scope.kind or null) == "complete-artifact" then
          [ ]
        else if
          (scope.kind or null) == "source-prefixes" && builtins.isList prefixes && prefixes != [ ]
        then
          builtins.filter (path: !(builtins.any (prefix: hasPrefix prefix path) prefixes)) paths
        else
          [ "/requestScope" ];
    in
    if escaped == [ ] then
      true
    else
      fail "NR_SCOPE_ESCAPE" (builtins.head escaped) "path is outside the declared request scope";

  makeCandidate =
    {
      input,
      requestScope,
      rootLockIdentity,
      producerRevision,
      protectedReferences ? [ ],
    }:
    let
      cpm = cpmFrom input;
      sourceIdentity = sourceIdentityFrom input;
      sourceDigest = sourceDigestFor cpm;
      base = {
        kind = schema.schema.bundle.kind;
        schemaRevision = schema.schema.bundle.revision;
        inherit requestScope protectedReferences;
        sources.cpm = {
          identity = sourceIdentity;
          digest = sourceDigest;
        };
        network.data = cpm;
        provenance = {
          producer = "network-realization-model";
          producerRepository = "network-realization-model";
          inherit producerRevision rootLockIdentity;
          schemaSetIdentity = schema.schemaSetIdentity;
          transformationRuleSet = "cpm-identity-v1";
          sourceArtifactDigest = sourceDigest;
        };
        upstreamCoverage = coverageFor sourceIdentity (sourceRecordsFor cpm);
      };
    in
    base // { bundleIdentity = schema.computeBundleIdentity base; };

  release =
    { input, candidate }:
    let
      _producer = validateProducerAccounting { inherit input candidate; };
      _coverage = validateUpstreamCoverage { inherit input candidate; };
      _scope = validateScope candidate;
      _schemaRevision =
        if (candidate.schemaRevision or null) == schema.schema.bundle.revision then
          true
        else
          fail "NR_SCHEMA_VALIDATION_FAILED" "/schemaRevision" "NR_SCHEMA_UNKNOWN";
      schemaValidation = schema.validateBundle candidate;
    in
    builtins.deepSeq [ _producer _coverage _scope _schemaRevision schemaValidation ] (
      candidate
      // {
        validation = schemaValidation // {
          validator = "network-realization-schema";
          validationIdentity = builtins.hashString "sha256" (
            builtins.toJSON {
              artifactIdentity = candidate.bundleIdentity;
              schemaSetIdentity = schema.schemaSetIdentity;
              scopeIdentity = candidate.requestScope.identity;
            }
          );
        };
      }
    );

  realize =
    args:
    release {
      input = args.input;
      candidate = makeCandidate args;
    };

  assertDeterministic =
    { first, second }:
    if
      builtins.toJSON first == builtins.toJSON second && first.bundleIdentity == second.bundleIdentity
    then
      true
    else
      fail "NR_NONDETERMINISTIC_BUNDLE" "/bundleIdentity"
        "equal inputs produced different canonical serialization";

  validatePlatformBindingAgainstBundle =
    {
      bundle,
      binding,
      expectedTarget,
    }:
    let
      bundleValidation = schema.validateBundle bundle;
      bindingValidation = schema.validatePlatformBinding binding;
      canonicalPaths = schema.paths.pathsFor {
        value = bundle.network;
        rootPath = "/network";
      };
      references = unique (collectCanonicalReferences binding.categories);
      referenceExists =
        reference: builtins.any (path: path == reference || hasPrefix "${reference}/" path) canonicalPaths;
      missingReferences = builtins.filter (reference: !(referenceExists reference)) references;
      _bundle =
        if binding.bundleIdentity == bundle.bundleIdentity then
          true
        else
          fail "NR_PLATFORM_BINDING_IDENTITY_MISMATCH" "/bundleIdentity" "stale canonical bundle reference";
      _target =
        if binding.target == expectedTarget then
          true
        else
          fail "NR_PLATFORM_BINDING_TARGET_MISMATCH" "/target"
            "expected ${expectedTarget}, observed ${binding.target}";
      _scope =
        if binding.requestScope == bundle.requestScope then
          true
        else
          fail "NR_PLATFORM_BINDING_TARGET_MISMATCH" "/requestScope" "binding and canonical scopes differ";
      _references =
        if missingReferences == [ ] then
          true
        else
          fail "NR_PLATFORM_BINDING_REFERENCE_MISSING" (builtins.head missingReferences)
            "canonical object is absent";
    in
    builtins.deepSeq [ bundleValidation bindingValidation _bundle _target _scope _references ] {
      valid = true;
      bundleIdentity = bundle.bundleIdentity;
      bindingIdentity = binding.bindingIdentity;
      target = expectedTarget;
      requestScope = bundle.requestScope;
    };

  validateRendererInput =
    {
      bundle,
      expectedTarget,
      platformBinding ? null,
    }:
    let
      bundleValidation = schema.validateBundle bundle;
      releaseValidation = bundle.validation or { };
      _released =
        if
          (releaseValidation.valid or false) == true
          && (releaseValidation.artifactIdentity or null) == bundle.bundleIdentity
          && (releaseValidation.schemaSetIdentity or null) == schema.schemaSetIdentity
        then
          true
        else
          fail "NR_RENDERER_BUNDLE_UNVALIDATED" "/validation"
            "bundle lacks the schema- and digest-bound release validation";
      _target = requireString "NR_RENDERER_TARGET_INVALID" "/expectedTarget" expectedTarget;
      bindingValidation =
        if platformBinding == null then
          null
        else
          let
            release = platformBinding.validation or { };
            _bindingReleased =
              if
                (release.valid or false) == true
                && (release.artifactIdentity or null) == platformBinding.bindingIdentity
                && (release.schemaSetIdentity or null) == schema.schemaSetIdentity
              then
                true
              else
                fail "NR_PLATFORM_BINDING_UNVALIDATED" "/validation"
                  "platform binding lacks the schema- and digest-bound validation";
            checked = validatePlatformBindingAgainstBundle {
              inherit bundle expectedTarget;
              binding = platformBinding;
            };
          in
          builtins.deepSeq _bindingReleased checked;
      semanticModel = bundle.network.data;
      controlPlaneEnvelope =
        if semanticModel ? control_plane_model then
          semanticModel
        else
          { control_plane_model = semanticModel; };
    in
    builtins.deepSeq [ bundleValidation _released _target bindingValidation ] {
      inherit
        bindingValidation
        bundleValidation
        controlPlaneEnvelope
        expectedTarget
        semanticModel
        ;
      bundleIdentity = bundle.bundleIdentity;
      bindingIdentity = if platformBinding == null then null else platformBinding.bindingIdentity;
      requestScope = bundle.requestScope;
    };
in
{
  inherit
    assertDeterministic
    destinationFor
    makeCandidate
    realize
    release
    sourceDigestFor
    validatePlatformBindingAgainstBundle
    validateProducerAccounting
    validateRendererInput
    validateScope
    validateUpstreamCoverage
    ;
}
