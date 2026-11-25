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
    let
      grouped = builtins.groupBy (v: toString v) values;
    in
    builtins.filter (key: builtins.length grouped.${key} > 1) (builtins.attrNames grouped);

  difference =
    left: right:
    let
      rightSet = builtins.listToAttrs (map (v: {
        name = v;
        value = true;
      }) right);
    in
    builtins.filter (v: !(builtins.hasAttr v rightSet)) left;

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

  # Upstream coverage is a predicate over the bundle, not a payload in it.
  #
  # Every realized path shares one classification and one versioned rule, so the
  # artifact declares those invariants once and carries a coverage identity
  # bound to the canonical artifact identity. The per-path accounting -- which
  # is one row per CPM leaf, 341,269 rows and 194 MB on the cobalt/neon sites --
  # is recomputed from `network.data` when it is checked, and is identical to
  # the array the artifact used to ship.
  coverageInvariants = {
    classification = "realized";
    transformationRule = "cpm-identity-v1";
  };

  coverageRowsFor =
    candidate:
    map (row: {
      sourcePath = row.sourcePath or null;
      destinationPath = row.destinationPath or null;
      inherit (coverageInvariants) classification transformationRule;
    }) (schema.canonicalCoverageRows candidate);

  # FS-161: protected references are opaque runtime references, not material.
  # The CPM carries them as filesystem paths (deployment/runtime secret files).
  # Projecting every such leaf into `protectedReferences` makes the schema's
  # protected-material checks load-bearing for real bundles instead of only for
  # fixtures, and gives consumers one complete list to bind against.
  protectedReferencePrefix = "/run/secrets/";

  collectProtectedReferences =
    value:
    if builtins.isString value then
      (if hasPrefix protectedReferencePrefix value then [ value ] else [ ])
    else if builtins.isAttrs value then
      builtins.concatLists (map (name: collectProtectedReferences value.${name}) (builtins.attrNames value))
    else if builtins.isList value then
      builtins.concatLists (map collectProtectedReferences value)
    else
      [ ];

  # Deterministic union of the references the bundle actually carries and any
  # explicitly supplied ones. Completeness is guaranteed by construction: a
  # producer cannot release a bundle that omits a reference its own content
  # names.
  protectedReferencesFor =
    { cpm, declared }:
    let
      derived = map (reference: { inherit reference; classification = "protected"; }) (
        unique (collectProtectedReferences cpm)
      );
      declaredRecords = requireList "NR_PROTECTED_VALUE_EXPOSED" "/protectedReferences" declared;
      byReference = builtins.listToAttrs (
        map (record: {
          name = record.reference;
          value = record;
        }) (derived ++ declaredRecords)
      );
    in
    map (name: byReference.${name}) (builtins.attrNames byReference);

  # The bundle's platform-neutral network content.
  #
  # `network.data` is the producer's CPM, handed through unchanged. A renderer
  # that reads it is reading the plain control-plane model, which
  # RR_RAW_CPM_INPUT forbids; the bundle added validation, identity, provenance
  # and coverage AROUND the CPM but no canonical content of its own. This
  # projects the collections the producer already publishes onto the bundle, so
  # a renderer can map canonical objects without reaching into the model.
  #
  # Only names the schema lists are projected, and only when the producer
  # actually carries them: realization makes declared meaning executable, it
  # does not manufacture a collection the CPM never emitted. A producer that
  # publishes nothing yields no `canonical` section (and the renderer that needs
  # one fails loudly where it is consumed).
  # The renderer-facing view, built from the schema's canonical collections only.
  # See src/structural-view.nix for why it lives here and not in a renderer.
  structuralViewFor = import ./structural-view.nix;

  canonicalFor =
    cpm:
    let
      # A producer may hand over the CPM envelope, or a build result that wraps
      # it (`{ control_plane_model = <envelope>; endpointInventory; ... }`).
      # The producer's canonical collections live on the envelope, so accept
      # both depths rather than making every producer reshape its artifact --
      # the alternative is that one producer's extra wrapper silently strips
      # every canonical collection from the bundle, and a renderer that maps
      # canonical content gets nothing:
      #
      #   network-renderer-nebula: ... the bundle carries no canonical site
      #   records
      #
      # Measured 2026-11-22: the nixos host pipeline passed the build result,
      # so `canonical` projected to `{ }` while `network.data` still resolved
      # through the schema's own fallback. The bundle looked valid and carried
      # no canonical content, which is the worst of both.
      hasCollection =
        value:
        builtins.isAttrs value
        && builtins.any (
          name: builtins.isList (value.${name} or null) || builtins.isAttrs (value.${name} or null)
        ) schema.schema.bundle.canonicalCollections;
      nested = cpm.control_plane_model or null;
      # Two carriers is an ambiguity, not a preference. If the artifact carries
      # canonical collections at the top level AND wraps an envelope that
      # carries different ones, projecting one of them silently chooses which
      # producer statement is true. Refuse it: only the producer can say which
      # is authoritative, and a guess here reaches every renderer.
      _ambiguous =
        if hasCollection cpm && hasCollection nested && builtins.toJSON (
          builtins.listToAttrs (
            map (name: { inherit name; value = cpm.${name}; }) (
              builtins.filter (name: cpm ? ${name}) schema.schema.bundle.canonicalCollections
            )
          )
        ) != builtins.toJSON (
          builtins.listToAttrs (
            map (name: { inherit name; value = nested.${name}; }) (
              builtins.filter (name: nested ? ${name}) schema.schema.bundle.canonicalCollections
            )
          )
        ) then
          fail "NR_CANONICAL_CARRIER_AMBIGUOUS" "/canonical"
            "the artifact carries canonical collections at both the top level and in the wrapped envelope, and they differ"
        else
          true;
      carrier =
        if hasCollection cpm then
          cpm
        else if hasCollection nested then
          nested
        else
          cpm;
      # The producer's published canonical collections, whichever name the
      # producer gave the stage it wraps them in.
      #
      # FS-310-HDS-040-SDS-010-SMS-100 (canonical-only consumption): the schema's
      # `bundle.canonicalCollections` list is CLOSED, and the projection two
      # lines below filters by it. That filter is where a collection the producer
      # publishes -- and the schema does not list -- is DROPPED. It is dropped
      # here, before any renderer exists, from a bundle that still validates; the
      # only symptom downstream is a renderer with nothing to map, which reads as
      # a renderer bug and is not one.
      #
      # Measured on the current tree: the producer publishes `canonicalForwarding`
      # and `canonicalOverlays`, the schema lists neither, so both vanish from
      # every bundle while the schema's own comment claims the list is "named
      # exactly as the producer publishes them".
      #
      # Fail here, at the loss, and name the file that has to change. The repair
      # (adding the names to the closed set) is a separate change to
      # network-realization-schema; until it lands the model refuses to produce a
      # silently incomplete bundle, which is the correct outcome.
      publishedCanonical = builtins.filter (
        name:
        hasPrefix "canonical" name
        && (builtins.isList (carrier.${name} or null) || builtins.isAttrs (carrier.${name} or null))
      ) (builtins.attrNames carrier);
      unlistedCollections = builtins.filter (
        name: !(builtins.elem name schema.schema.bundle.canonicalCollections)
      ) publishedCanonical;
      _complete =
        if unlistedCollections == [ ] then
          true
        else
          fail "NR_CANONICAL_COLLECTION_DROPPED" "/canonical/${builtins.head unlistedCollections}"
            "FS-310-HDS-040-SDS-010-SMS-100: the producer publishes '${builtins.head unlistedCollections}', but network-realization-schema/schema/default.nix -> bundle.canonicalCollections does not list it, so this projection would drop it and hand every renderer a bundle that validates and is missing published facts. Add it to that list (and remove the names the producer no longer publishes) in the schema, or stop publishing it in the producer: ${builtins.concatStringsSep ", " unlistedCollections}";
      present = builtins.filter (
        name: builtins.isList (carrier.${name} or null) || builtins.isAttrs (carrier.${name} or null)
      ) schema.schema.bundle.canonicalCollections;
    in
    builtins.deepSeq [ _ambiguous _complete ] (
      builtins.listToAttrs (
        map (name: {
          inherit name;
          value = carrier.${name};
        }) present
      )
    );

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

  # FS-161: a platform binding may reference protected material, but only a
  # reference the canonical bundle already declares. A binding that names its
  # own secret path is adding a second, unvalidated authority (and could point
  # at material the bundle never accounted for).
  collectProtectedReferencePaths =
    value:
    if builtins.isAttrs value then
      builtins.concatLists (
        map (name: collectProtectedReferencePaths value.${name}) (builtins.attrNames value)
      )
    else if builtins.isList value then
      builtins.concatLists (map collectProtectedReferencePaths value)
    else if builtins.isString value then
      (if hasPrefix "/run/secrets/" value then [ value ] else [ ])
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
      # The accounting is recomputed from the candidate's own network content,
      # so there is no delivered array to read and no way for the two to drift.
      coverage = requireList "NR_UPSTREAM_PATH_UNACCOUNTED" "/coverageIdentity" (
        schema.canonicalCoverageRows candidate
      );
      coveragePaths = map (row: row.sourcePath or "") coverage;
      missing = difference sourcePaths coveragePaths;
      incompleteProvenance = builtins.filter (
        row:
        (coverageInvariants.transformationRule or null) != "cpm-identity-v1"
        || (candidate.coverageInvariants.transformationRule or null) != "cpm-identity-v1"
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
      coverage = requireList "NR_UPSTREAM_COVERAGE_MISSING" "/coverageIdentity" (
        schema.canonicalCoverageRows candidate
      );
      coverageSourcePaths = map (row: row.sourcePath or "") coverage;
      coverageDestinationPaths = map (row: row.destinationPath or "") coverage;
      duplicateSources = duplicates coverageSourcePaths;
      missingSources = difference sourcePaths coverageSourcePaths;
      unexpectedSources = difference coverageSourcePaths sourcePaths;
      invalidDestinations = difference coverageDestinationPaths canonicalPaths;
      unknownRules = builtins.filter (
        row: (row.transformationRule or null) != "cpm-identity-v1"
      ) coverage;
      wrongProvenance = builtins.filter (
        row: (candidate.coverageInvariants.transformationRule or null) != "cpm-identity-v1"
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
      paths = map (row: row.sourcePath or "") (schema.canonicalCoverageRows candidate);
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

  # FS-310-HDS-040-SDS-010-SMS-100 (canonical-only consumption) and FS-161 (the
  # canonical path is the trace): a canonical record is part of the artifact only
  # when the GAMP chain accounts for it. "Accounts for it" is not an opinion here:
  # `schema.canonicalCoverageRows` derives one row per CPM leaf, and a record whose
  # `canonicalPath` has no row was published by the producer without a source
  # statement.
  #
  # Such a record used to be carried and diagnosed as an ORPHAN
  # (`NR_ORPHAN_CANONICAL_PATH`). An orphan is not a classification the model may
  # hold: a path nothing upstream produced is not a canonical object, it is a
  # stray, and carrying it hands every renderer a record with no file, no row and
  # no trace ID behind it. It is DROPPED at the projection, so the bug it produces
  # is "the collection is short one member" -- visible against the producer's own
  # list -- instead of "one record in the collection is untraceable" -- visible
  # only if somebody audits every path.
  #
  # The filter is shape-agnostic on purpose: the producer's collections are lists
  # (interfaces, routes, rules) and nested attrsets (sites.byEnterprise,
  # runtimeTargets.targets). Any attrs value carrying a `canonicalPath` is a record
  # and is tested; everything else is walked.
  dropUnaccountedCanonical =
    cpm: value:
    let
      # A published record's `canonicalPath` names a location in the producer's own
      # model. Coherence with the GAMP chain is exactly this: the location exists. The
      # coverage rows are derived from the same model's leaves, so "some row accounts for
      # it" and "the model has it" are the same statement, and this is the cheap form --
      # one attribute path walk per record instead of a scan over every leaf.
      #
      # `/network/data` is the bundle-side root; the model is that subtree.
      stripRoot =
        path:
        if builtins.substring 0 13 path == "/network/data" then
          builtins.substring 13 (builtins.stringLength path - 13) path
        else
          path;
      resolves =
        path:
        let
          segments = builtins.filter (part: builtins.isString part && part != "") (
            builtins.split "/" (stripRoot path)
          );
          step =
            node: segment:
            if builtins.isList node then
              let
                index = builtins.fromJSON segment;
              in
              if builtins.isInt index && index >= 0 && index < builtins.length node then
                builtins.elemAt node index
              else
                null
            else if builtins.isAttrs node && node ? ${segment} then
              node.${segment}
            else
              null;
        in
        segments != [ ] && (builtins.foldl' step cpm segments) != null;
      keep =
        item:
        !(builtins.isAttrs item) || !(item ? canonicalPath) || resolves item.canonicalPath;
      walk =
        node:
        if builtins.isList node then
          builtins.filter keep (map walk node)
        else if builtins.isAttrs node then
          builtins.mapAttrs (_name: child: walk child) node
        else
          node;
    in
    walk value;

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
      resolvedProtectedReferences = protectedReferencesFor {
        inherit cpm;
        declared = protectedReferences;
      };
      sourceIdentity = sourceIdentityFrom input;
      sourceDigest = sourceDigestFor cpm;
      base = {
        kind = schema.schema.bundle.kind;
        schemaRevision = schema.schema.bundle.revision;
        inherit requestScope;
        protectedReferences = resolvedProtectedReferences;
        sources.cpm = {
          identity = sourceIdentity;
          digest = sourceDigest;
        };
        network.data = cpm;
        canonical = dropUnaccountedCanonical cpm (canonicalFor cpm);
        provenance = {
          producer = "network-realization-model";
          producerRepository = "network-realization-model";
          inherit producerRevision rootLockIdentity;
          schemaSetIdentity = schema.schemaSetIdentity;
          transformationRuleSet = "cpm-identity-v1";
          sourceArtifactDigest = sourceDigest;
        };
        upstreamCoverageIdentity = sourceIdentity;
        coverageInvariants = coverageInvariants;
      };
      withCoverage = base // { coverageIdentity = schema.computeCoverageIdentity base; };
    in
    withCoverage // { bundleIdentity = schema.computeBundleIdentity withCoverage; };

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
      declaredProtected = map (record: record.reference or null) (bundle.protectedReferences or [ ]);
      bindingProtected = unique (collectProtectedReferencePaths binding.categories);
      undeclaredProtected = builtins.filter (
        reference: !(builtins.elem reference declaredProtected)
      ) bindingProtected;
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
      _protected =
        if undeclaredProtected == [ ] then
          true
        else
          fail "NR_PLATFORM_BINDING_REFERENCE_MISSING" (builtins.head undeclaredProtected)
            "protected reference is not declared by the canonical bundle";
    in
    builtins.deepSeq
      [ bundleValidation bindingValidation _bundle _target _scope _references _protected ]
      {
      valid = true;
      bundleIdentity = bundle.bundleIdentity;
      bindingIdentity = binding.bindingIdentity;
      target = expectedTarget;
      requestScope = bundle.requestScope;
    };

  # Accept the producer's own release verdict rather than recomputing it.
  #
  # `release` validated the bundle and bound the result to `bundleIdentity`.
  # Re-running `schema.validateBundle` in the renderer-input gate repeated the
  # full coverage enumeration (one row per CPM leaf) and a complete canonical
  # serialisation of the bundle, and neither result is consumed by any
  # renderer. The stamp is re-checked here for shape and identity instead, so a
  # missing, forged, or stale verdict still fails closed.
  bundledValidation =
    bundle:
    let
      release = bundle.validation or null;
      shape = requireAttrs "NR_RENDERER_BUNDLE_UNVALIDATED" "/validation" release;
      identity = requireString "NR_RENDERER_BUNDLE_UNVALIDATED" "/validation/artifactIdentity" (
        shape.artifactIdentity or null
      );
      authenticated =
        if shape.valid or false then
          true
        else
          fail "NR_RENDERER_BUNDLE_UNVALIDATED" "/validation/valid"
            "bundle release validation is not marked valid";
      _identity =
        if identity == (bundle.bundleIdentity or null) then
          true
        else
          fail "NR_RENDERER_BUNDLE_UNVALIDATED" "/validation/artifactIdentity"
            "release validation is bound to a different artifact identity";
    in
    builtins.deepSeq [ shape authenticated _identity ] release;

  validateRendererInput =
    {
      bundle,
      expectedTarget,
      platformBinding ? null,
    }:
    let
      # The producer already validated this artifact in `release`, and bound that
      # verdict to `bundleIdentity`. Re-running `schema.validateBundle` here
      # repeated the whole coverage enumeration and a full canonical
      # serialisation for an answer the bundle already carries, and no renderer
      # consumes either. Trust the stamp, and prove it still describes these
      # exact bytes by recomputing the identity from the bundle itself.
      bundleValidation = bundledValidation bundle;
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
      # Recompute the identity from the bundle content. Comparing the stamped
      # `validation.artifactIdentity` with the stamped `bundleIdentity` proves
      # nothing about the bytes: a consumer that receives a released bundle and
      # then has a field mutated still carries both stamps unchanged. The
      # recomputation is one hash, so the fast path stays fast while a mutated
      # bundle is rejected instead of rendered.
      computedIdentity = schema.computeBundleIdentity bundle;
      _identityIntact =
        if
          (releaseValidation.artifactIdentity or null) == bundle.bundleIdentity
          && computedIdentity == bundle.bundleIdentity
        then
          true
        else
          fail "NR_ARTIFACT_DIGEST_MISMATCH" "/bundleIdentity"
            "released identity does not match the supplied bundle content";
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
      # FS-310-HDS-040-SDS-010-SMS-100 — RENDERER CANONICAL-ONLY CONSUMPTION
      #
      # The row says: "Every `network-renderer-*` module shall receive network-semantic
      # input only as one validated canonical realization bundle ... CPM output is
      # upstream authority consumed by `network-realization-model`; it is not a public
      # renderer input", and its rejection list names "CPM output, peer-renderer output,
      # unvalidated sidecars, and renderer-local parallel network models".
      #
      # The bundle still CARRIES the producer artifact: `computeBundleIdentity` hashes
      # it, coverage counts it, and `schema.validateBundle` reads it. What changes here
      # is the HANDOVER. This function used to return `semanticModel`, `semanticArtifact`
      # and `controlPlaneEnvelope` -- three names for `bundle.network.data`, the plain
      # control-plane model -- and the comment on `semanticArtifact` said so: "Same
      # value, neutral name: nothing about the bundle changes". A renderer that read
      # `cpm.model.canonicalSites` through that name was reading raw CPM while every
      # gate reported canonical consumption, which is why the schema's closed-set drift
      # could drop two published collections from every bundle and no renderer noticed.
      #
      # The names are kept and THROW rather than deleted: a deleted attribute fails as
      # "attribute missing", which reads as a typo and gets repaired with `or { }` --
      # the silent-substitution shape this row exists to prevent. A throw names the row,
      # says what to map instead, and refuses the fallback in the same sentence.
      withdrawn =
        what:
        throw (
          "FS-310-HDS-040-SDS-010-SMS-100: '${what}' is not a renderer input. A renderer "
          + "receives network semantics only as the validated bundle's 'canonical' "
          + "collections; the plain control-plane model the bundle wraps is upstream "
          + "authority for network-realization-model and is not a public renderer input. "
          + "Repair the renderer: map 'canonical.<collection>' and keep the canonical path "
          + "it came from. Do not add a raw-CPM fallback here -- a renderer-local parallel "
          + "network model is the same violation in a different shape."
        );

      semanticModel = withdrawn "semanticModel";
      controlPlaneEnvelope = withdrawn "controlPlaneEnvelope";
      semanticArtifact = withdrawn "semanticArtifact";

      # What a renderer MAY map. `canonical` is the producer's published collections
      # projected by `canonicalFor`; a bundle from a producer that publishes none has no
      # members here, and a renderer that needs one must fail loudly at that access
      # rather than fall back to the model (the throw above is the fallback's dead end).
      canonical =
        if bundle ? canonical then
          bundle.canonical
        else
          throw (
            "FS-310-HDS-040-SDS-010-SMS-100: the bundle carries no 'canonical' section, so "
            + "this renderer has nothing it is allowed to map. The projection is done by "
            + "network-realization-model/lib.realize -> canonicalFor; a bundle without it "
            + "was built outside the producer handoff."
          );

      # The renderer-facing view, for consumers that serialise the input instead of
      # reading attributes in Nix (the ContainerLab backend writes JSON). It contains the
      # canonical collections and the stamps that bind them, and deliberately no
      # `network` key: a serialised renderer input that carries the raw artifact is the
      # same bypass with a file in between.
      rendererInput = {
        inherit
          canonical
          expectedTarget
          bindingValidation
          bundleValidation
          ;
        requestScope = bundle.requestScope;
        # The canonical section's own digest, so a consumer that only ever sees this
        # projection can still tell whether the collections changed. The full-bundle
        # identity covers `network` too, which is exactly the part this view withholds;
        # recomputing it here would require the artifact back, so the projection
        # carries its own binding instead.
        canonicalDigest = builtins.hashString "sha256" (
          builtins.toJSON (builtins.listToAttrs (map (name: { inherit name; value = canonical.${name}; }) (builtins.attrNames canonical)))
        );
        schemaSetIdentity = bundle.provenance.schemaSetIdentity or null;
        bundleIdentity = bundle.bundleIdentity;
        bindingIdentity = if platformBinding == null then null else platformBinding.bindingIdentity;
        validatedPlatformBinding = platformBinding;
        provenance = bundle.provenance or { };
        validation = bundle.validation or { };
        withheld = [
          "network"
          "network.data"
          "semanticModel"
          "semanticArtifact"
          "controlPlaneEnvelope"
        ];
      };
    in
    builtins.deepSeq [ bundleValidation _released _identityIntact _target bindingValidation ] {
      inherit
        bindingValidation
        bundleValidation
        canonical
        controlPlaneEnvelope
        semanticArtifact
        expectedTarget
        rendererInput
        semanticModel
        ;
      bundleIdentity = bundle.bundleIdentity;
      bindingIdentity = if platformBinding == null then null else platformBinding.bindingIdentity;
      validatedPlatformBinding = platformBinding;
      requestScope = bundle.requestScope;
      # What a renderer maps: the canonical collections, plus the structured
      # envelope the renderer modules read, derived from those collections alone.
      # A renderer that wants the structure no longer has to build its own.
      structuralView = structuralViewFor {
        inherit canonical;
        inherit (bundle) platformBinding;
      };
    };
in
{
  inherit
    assertDeterministic
    canonicalFor
    coverageInvariants
    coverageRowsFor
    destinationFor
    makeCandidate
    protectedReferencesFor
    realize
    release
    sourceDigestFor
    structuralViewFor
    validatePlatformBindingAgainstBundle
    validateProducerAccounting
    validateRendererInput
    validateScope
    validateUpstreamCoverage
    ;
}
