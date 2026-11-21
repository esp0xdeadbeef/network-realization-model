# SYNTHETIC FIXTURE -- NOT a producer contract.
#
# This file is hand-written. It is not the output of any CPM, and the shape it
# asserts is not guaranteed to be one a real CPM produces.
#
# WHY THAT MATTERS (measured 2026-11-21). Seven repositories -- this one's
# tests plus network-renderer-{nixos,openconfig,nebula,containerlab-linux-backend,
# access-endpoint-nixos} and clab-main -- build their POSITIVE path from this
# file. It carries `canonicalInterfaces`, hand-written here:
#
#     canonicalInterfaces = [ { identity.name = "lan0";
#                               type.ianaIdentity = "iana-if-type:ethernetCsmacd"; ... } ];
#
# No real CPM emits that collection. Verified: it is absent from the CPM
# compiled for a site HAT intent AND from the CPM compiled for
# network-labs/examples/single-wan-uplink-static-egress, and it appears nowhere
# in network-realization-model or network-realization-schema. So every peer
# renderer's positive test was validated against a CPM shape that does not exist,
# and the absence of the field -- which makes a real site completely unrenderable
# to OpenConfig -- could not be seen from any of those suites.
#
# Consequences, and what to do instead:
#
#   * Keep this file for unit cases whose ASSERTED VALUES matter to consumers
#     (the interface name "lan0", mtu 1500, the description text, the
#     canonicalPath indices). Changing it silently breaks them.
#   * Do not treat it as evidence that the production path works. tests/default.nix
#     also realises `realCpm`, compiled by network-control-plane-model from
#     network-labs/examples/single-wan-uplink-static-egress, for exactly that.
#   * The producer-boundary assertion -- that a real CPM carries the identity a
#     peer renderer maps -- lives where the field is consumed:
#     network-renderer-openconfig `canonical-renderer-input`.
let
  controlPlaneModel = {
    canonicalInterfaces = [
      {
        canonicalPath = "/network/data/canonicalInterfaces/0";
        identity.name = "lan0";
        type.ianaIdentity = "iana-if-type:ethernetCsmacd";
        description = "explicit fixture tenant interface";
        enabled = true;
        mtu = 1500;
      }
    ];
    data.example.site = {
      runtimeTargets.router = {
        role = "core";
        interfaces.lan = {
          kind = "tenant";
          runtimeIfName = "lan0";
          mtu = 1500;
        };
        services.dns = {
          recursion = true;
          listenerAddresses = [ "192.0.2.53" ];
        };
      };
    };
    meta.source = "fixture";
  };
in
{
  kind = "network-control-plane-artifact";
  artifactIdentity = "fixture-cpm-v1";
  artifactDigest = builtins.hashString "sha256" (builtins.toJSON controlPlaneModel);
  control_plane_model = controlPlaneModel;
}
