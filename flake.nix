{
  description = "Circle call history reader and nearby-alert push service";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in {
      packages = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in rec {
          circle-calls = pkgs.writeShellApplication {
            name = "circle-calls";
            text = ''exec ${pkgs.python3}/bin/python3 ${./scripts/call_log.py} "$@"'';
          };
          # Swift 6 from this flake's own nixpkgs; consumers need not follow it.
          circle-push = pkgs.callPackage ./nix/push-package.nix { };
          default = circle-calls;
        });
      darwinModules.default = import ./nix/darwin-module.nix self;
      apps = eachSystem (system: {
        default = { type = "app"; program = "${self.packages.${system}.circle-calls}/bin/circle-calls"; };
      });
    };
}
