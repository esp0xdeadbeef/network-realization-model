# The renderer-facing structural view of a validated bundle.
#
# WHY THIS LIVES IN network-realization-model
# -------------------------------------------
# A renderer may map the bundle's canonical collections and nothing else
# (FS-310-HDS-040-SDS-010-SMS-100): the plain control-plane model is upstream
# authority, and `validateRendererInput` withdraws every name that handed it back
# (`controlPlaneEnvelope`, `semanticModel`, `semanticArtifact`).
#
# That is correct, and it left a gap: the renderer modules read a *structured*
# shape -- `cpm.model.data.<enterprise>.<site>.runtimeTargets`,
# `cpm.model.canonicalSites.byEnterprise`, `cpm.model.forwardingModel` -- so every
# renderer that wanted to obey the gate had to synthesise that shape itself. Each
# one did it differently and lossily: network-renderer-nixos had its own
# `s88/Unit/mapping/canonical-structural-view.nix`, which built `model.data` from
# `canonicalSites.byEnterprise` and dropped `canonicalSites` itself, so the
# renderer's own firewall lookup then could not find the site record it needed
# (measured: FS-540-HDS-010-SDS-010-SMS-042 and -020 on network-renderer-nixos).
#
# A renderer-local parallel network model is the same violation in a different
# shape, so the view is built here, once, from the bundle's canonical collections
# only. The shape mirrors the producer's envelope (`model` carrying `data` and the
# canonical collections) because that is what the modules already map -- the point
# is where the values come from, not what they are called.
#
# Nothing is re-derived and nothing outside the schema's closed set is projected:
# `canonicalFor` has already filtered by `bundle.canonicalCollections`, so this
# function can only carry names the schema knows.
{
  canonical ? { },
  platformBinding ? null,
}:

let
  sites = canonical.canonicalSites or { };
  byEnterprise = sites.byEnterprise or { };

  canonicalTargets = (canonical.canonicalRuntimeTargets or { }).targets or [ ];

  targetsForSite =
    enterprise: siteName:
    let
      matching = builtins.filter (
        t: (t.enterprise or null) == enterprise && (t.site or null) == siteName
      ) canonicalTargets;
    in
    builtins.listToAttrs (
      map (t: {
        name = t.target or (t.logicalNode or { }).name;
        value = t;
      }) matching
    );

  # A site record that publishes no runtime targets of its own takes them from
  # `canonicalRuntimeTargets`, which is the collection that owns them. A record
  # that carries them keeps its own: the producer's value wins.
  siteWithCanonicalTargets =
    enterprise: siteName: siteRecord:
    let
      own = siteRecord.runtimeTargets or null;
      fromCollection = targetsForSite enterprise siteName;
    in
    if builtins.isAttrs own && own != { } then
      siteRecord
    else
      siteRecord // { runtimeTargets = fromCollection; };

  data = builtins.mapAttrs (
    enterprise: siteTree:
    builtins.mapAttrs (
      siteName: siteRecord: siteWithCanonicalTargets enterprise siteName siteRecord
    ) siteTree
  ) byEnterprise;

  bindingCategories =
    if builtins.isAttrs platformBinding then platformBinding.categories or { } else { };
  bindingDeployment =
    if builtins.isAttrs (bindingCategories.deployment or null) then
      bindingCategories.deployment
    else
      { };
  containerTargets =
    if builtins.isAttrs (bindingDeployment.containerTargets or null) then
      bindingDeployment.containerTargets
    else
      { };
  declaredHosts =
    if builtins.isAttrs (bindingDeployment.hosts or null) then bindingDeployment.hosts else { };
  bindingHosts =
    declaredHosts
    // builtins.listToAttrs (
      map (h: {
        name = h;
        value = declaredHosts.${h} or { };
      }) (builtins.attrNames containerTargets)
    );

  deploymentHosts = bindingHosts;
  deployment = bindingDeployment;

  # The canonical collections, under the names the producer's envelope uses, so a
  # consumer maps them by name instead of reaching for `network.data`.
  model = {
    inherit data;
    canonicalInterfaces = canonical.canonicalInterfaces or { };
    canonicalRoutes = canonical.canonicalRoutes or [ ];
    canonicalOverlays = canonical.canonicalOverlays or { };
    canonicalSites = canonical.canonicalSites or { };
    canonicalRuntimeTargets = canonical.canonicalRuntimeTargets or { };
    canonicalForwarding = canonical.canonicalForwarding or { };
  };
in
{
  inherit model deploymentHosts deployment;

  # The flat collections, for a consumer that maps them directly rather than
  # through the structural envelope.
  inherit (canonical)
    canonicalInterfaces
    canonicalRoutes
    canonicalOverlays
    canonicalSites
    canonicalRuntimeTargets
    canonicalForwarding
    ;

  canonical = canonical;
}
