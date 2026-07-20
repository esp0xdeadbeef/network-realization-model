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
