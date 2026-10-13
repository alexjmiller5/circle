# nix-darwin module: Circle's nearby-alert push service as a launchd user agent.
#
# It runs in the console user's GUI session so its secret commands can read the
# login Keychain and Apple's geocoder is available. Phones register through
# `tailscale serve`, which adds the tailnet user as Tailscale-User-Login.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.circle-push;
  label = "com.alexmiller.circle-push";
  home = "/Users/${cfg.user}";
  logDir = "${home}/Library/Logs/circle-push";
in
{
  options.services.circle-push = {
    enable = lib.mkEnableOption "Circle's nearby-alert push service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.circle-push;
      description = "Package providing `circle-push`.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = "Console user whose session runs the agent.";
    };

    hubUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://soma.example.workers.dev";
      description = "Base URL of the soma hub holding the streams and the people table.";
    };

    hubTokenCommand = lib.mkOption {
      type = lib.types.str;
      description = ''
        Command printing a hub token granted exactly the reads below: both
        streams and the people table's id, name and deleted_at columns.
      '';
    };

    apnsKeyCommand = lib.mkOption {
      type = lib.types.str;
      description = "Command printing the APNs auth key (.p8 text, or base64 of it).";
    };

    teamId = lib.mkOption { type = lib.types.str; description = "Apple Developer team id."; };
    keyId = lib.mkOption { type = lib.types.str; description = "APNs auth key id."; };

    topic = lib.mkOption {
      type = lib.types.str;
      default = "com.alexmiller.circle";
      description = "Bundle id of the Circle app receiving the pushes.";
    };

    checksStream = lib.mkOption { type = lib.types.str; description = "Stream of Find My city checks."; };
    locationStream = lib.mkOption { type = lib.types.str; description = "Stream whose latest append is your own location fix (lat/lon)."; };
    peopleTable = lib.mkOption { type = lib.types.str; description = "Table holding the person ids the checks name."; };
    peopleNameColumn = lib.mkOption { type = lib.types.str; description = "Display-name column of that table."; };

    allowedLogins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Further tailnet logins allowed to register a phone.";
    };

    allowTailnetOwner = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept phones of this machine's own tailnet owner (read from `tailscale status`).";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Loopback port for phone registrations.";
    };

    tailscaleHttpsPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8445;
      description = "Expose registrations on the tailnet at https://<this machine>:<port> with `tailscale serve`.";
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Seconds between evaluations.";
    };

    hideNames = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Lock-screen privacy: alerts carry neither the friend's name nor the place.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      /usr/bin/install -d -o ${cfg.user} -g staff ${logDir}
      ${lib.optionalString (cfg.tailscaleHttpsPort != null) ''
        ${config.services.tailscale.package}/bin/tailscale serve --bg --https=${toString cfg.tailscaleHttpsPort} \
          http://127.0.0.1:${toString cfg.listenPort} >/dev/null || echo "circle-push: tailscale serve failed"
      ''}
      _uid="$(/usr/bin/id -u ${cfg.user})"
      /bin/launchctl kickstart -k "gui/$_uid/${label}" >/dev/null 2>&1 || true
    '';

    launchd.user.agents.circle-push.serviceConfig = {
      Label = label;
      ProgramArguments = [
        (lib.getExe cfg.package) "run"
        "--hub" cfg.hubUrl
        "--hub-token-cmd" cfg.hubTokenCommand
        "--apns-key-cmd" cfg.apnsKeyCommand
        "--team-id" cfg.teamId
        "--key-id" cfg.keyId
        "--topic" cfg.topic
        "--checks-stream" cfg.checksStream
        "--location-stream" cfg.locationStream
        "--people-table" cfg.peopleTable
        "--people-name-column" cfg.peopleNameColumn
        "--listen-port" (toString cfg.listenPort)
        "--interval" (toString cfg.interval)
      ] ++ lib.concatMap (login: [ "--allowed-login" login ]) cfg.allowedLogins
        ++ lib.optionals cfg.allowTailnetOwner [ "--allow-tailnet-owner" "--tailscale" "${config.services.tailscale.package}/bin/tailscale" ]
        ++ lib.optional cfg.hideNames "--hide-names";
      KeepAlive = true;
      RunAtLoad = true;
      ThrottleInterval = 60;
      LimitLoadToSessionType = "Aqua";
      StandardOutPath = "${logDir}/push.log";
      StandardErrorPath = "${logDir}/push.log";
    };
  };
}
