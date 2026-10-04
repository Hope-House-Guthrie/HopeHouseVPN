{
  config,
  lib,
  ...
}:

let
  cfg = config.services.hope-house-vpn;
  network = import ./network.nix;

  # Determine if current host is in network map
  self =
    network.${cfg.hostName}
      or (throw "hope-house-vpn: Host '${cfg.hostName}' not found in network.nix");

  # Helper: build peer configuration for a target node
  makePeer =
    name: node:
    let
      isSelf = name == cfg.hostName;
      hasEndpoint = node ? endpoint && node.endpoint != null;
    in
    if isSelf then
      null
    else
      {
        PublicKey = node.publicKey;
        AllowedIPs = [ "${node.ipv4Address}/32" ];

        # Set Endpoint and PersistentKeepalive if target node has a public endpoint
        # and the current host itself is not acting as an endpoint to it.
        Endpoint = if hasEndpoint then "${node.endpoint}:${toString cfg.port}" else null;
        PersistentKeepalive = if hasEndpoint then cfg.keepalive else null;
      };

  # Filter out null entries (self) and generate clean peer list
  rawPeers = lib.mapAttrsToList makePeer network;
  peers = builtins.filter (p: p != null) rawPeers;

  # Remove null attributes inside peer blocks (e.g., Endpoint/PersistentKeepalive when peer is not an endpoint)
  cleanPeers = map (p: lib.filterAttrs (_: v: v != null) p) peers;

  isEndpointHost = self ? endpoint && self.endpoint != null;
in
{
  options.services.hope-house-vpn = {
    enable = lib.mkEnableOption "Hope House WireGuard VPN service";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Host key corresponding to an entry in network.nix.";
    };

    interfaceName = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Name of the WireGuard interface.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 42656;
      description = "UDP port for WireGuard listener.";
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the age secret file containing the WireGuard private key.";
    };

    keepalive = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 25;
      description = "PersistentKeepalive value (in seconds) for connecting to endpoints.";
    };

    firewallMark = lib.mkOption {
      type = lib.types.int;
      default = 42;
      description = "FirewallMark value for systemd-networkd netdev.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Open UDP port on firewall if node has an endpoint listener or needs inbound UDP access
    networking.firewall.allowedUDPPorts = lib.optionals isEndpointHost [ cfg.port ];

    networking.useNetworkd = lib.mkDefault true;

    systemd.network = {
      enable = true;

      networks."50-${cfg.interfaceName}" = {
        matchConfig.Name = cfg.interfaceName;
        address = [ "${self.ipv4Address}/32" ];
      };

      netdevs."50-${cfg.interfaceName}" = {
        netdevConfig = {
          Kind = "wireguard";
          Name = cfg.interfaceName;
        };

        wireguardConfig = {
          ListenPort = cfg.port;
          PrivateKeyFile = cfg.privateKeyFile;
          RouteTable = "main";
          FirewallMark = cfg.firewallMark;
        };

        wireguardPeers = cleanPeers;
      };
    };
  };
}
