{
  model ? import ../src/default.nix {
    schema = import ../../network-realization-schema/lib/default.nix;
  },
  input ? import ./cpm-result.nix,
}:

model.realize {
  inherit input;
  requestScope = {
    kind = "complete-artifact";
    identity = "fixture-complete-artifact";
  };
  rootLockIdentity = "fixture-root-lock";
  producerRevision = "fixture-realization-model";
}
