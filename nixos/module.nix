# todo: this doesn't allow peers to ping each other (Destination address required); peers can ping the endpoint peer and vice versa
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

  isEndpointHost = self ? endpoint && self.endpoint != null;

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

        # If connecting to an endpoint host, route the whole VPN subnet through it.
        # Otherwise, restrict to that specific peer's /32 IP.
        AllowedIPs = if hasEndpoint then [ cfg.subnetCidr ] else [ "${node.ipv4Address}/32" ];

        # Set Endpoint and PersistentKeepalive if target node has a public endpoint
        Endpoint = if hasEndpoint then "${node.endpoint}:${toString cfg.port}" else null;
        PersistentKeepalive = if hasEndpoint then cfg.keepalive else null;
      };

  # Filter out null entries (self) and generate clean peer list
  rawPeers = lib.mapAttrsToList makePeer network;
  peers = builtins.filter (p: p != null) rawPeers;

  # Remove null attributes inside peer blocks
  cleanPeers = map (p: lib.filterAttrs (_: v: v != null) p) peers;
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

    subnetCidr = lib.mkOption {
      type = lib.types.str;
      default = "172.16.42.0/24";
      description = "VPN subnet CIDR used for peer-to-peer routing through endpoint nodes.";
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the secret file containing the WireGuard private key.";
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
    # Open UDP port on firewall if node acts as an endpoint
    networking.firewall.allowedUDPPorts = lib.optionals isEndpointHost [ cfg.port ];

    # Trust VPN interface traffic on firewall
    networking.firewall.trustedInterfaces = [ cfg.interfaceName ];

    networking.firewall.extraCommands = lib.mkIf isEndpointHost ''
      iptables -A FORWARD -i ${cfg.interfaceName} -o ${cfg.interfaceName} -j ACCEPT
    '';

    # Enable IPv4 forwarding at kernel level if host is an endpoint router
    boot.kernel.sysctl = lib.mkIf isEndpointHost {
      "net.ipv4.ip_forward" = 1;
    };

    networking.useNetworkd = lib.mkDefault true;

    systemd.network = {
      enable = true;

      networks."50-${cfg.interfaceName}" = {
        matchConfig.Name = cfg.interfaceName;

        # 1. Assign local address using subnet mask length instead of /32
        # Extracts CIDR suffix length (e.g., "24" from "172.16.42.0/24")
        address = [ "${self.ipv4Address}/${lib.last (lib.splitString "/" cfg.subnetCidr)}" ];

        # 2. Force systemd-networkd to add a kernel route for the entire VPN subnet via wg0
        routes = [
          {
            Destination = cfg.subnetCidr;
          }
        ];
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
