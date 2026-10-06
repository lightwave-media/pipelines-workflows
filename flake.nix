{
  description = "pipelines-workflows — the dev shell and the gate, on the fleet's Nix template";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/79b35bf0bda5cd110f856aa5b5b2c5ba4460dbf5";

  outputs = { self, nixpkgs }: import ./nix/fleet.nix {
    inherit nixpkgs;
    name = "pipelines-workflows";
    kinds = [ "shell" ];
    # Today's `mise run ci`, step for step.
    gate = [
      "shellcheck --severity=warning scripts/*.sh"
      "bash scripts/check-actions-pinned-test.sh"
      "bash scripts/check-actions-pinned.sh"
    ];
  };
}
