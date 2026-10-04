{
  description = "Hope House VPN";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-26.05";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
      };

      network = import ./nixos/network.nix { };

      module = ./nixos/module.nix;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nixd
          nixfmt
          starship
          wireguard-tools
        ];

        shellHook = ''
          eval "$(starship init bash)"
        '';
      };

      lib = {
        inherit network;
      };

      nixosModules = {
        hopeHouseVPN = module;
        default = module;
      };
    };
}
