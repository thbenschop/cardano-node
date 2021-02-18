{ config
, lib
, pkgs
, ... }:

with lib; with builtins;
let
  cfg = config.services.cardano-node;
  inherit (cfg.cardanoNodePkgs) commonLib cardano-node cardano-node-profiled cardano-node-eventlogged cardano-node-asserted;
  envConfig = cfg.environments.${cfg.environment}; systemdServiceName = "cardano-node${optionalString cfg.instanced "@"}";
  runtimeDir = if cfg.runtimeDir == null then cfg.stateDir else "/run/${cfg.runtimeDir}";
  mkScript = cfg: i: let
    instanceConfig = cfg.nodeConfig // (optionalAttrs (cfg.nodeConfig ? hasEKG) {
      hasEKG = cfg.nodeConfig.hasEKG + i;
    }) // (optionalAttrs (cfg.nodeConfig ? hasPrometheus) {
      hasPrometheus = map (n: if isInt n then n + i else n) cfg.nodeConfig.hasPrometheus;
    });
    realNodeConfigFile = if (cfg.environment == "selfnode" || cfg.environment == "shelley_selfnode") then "${cfg.stateDir}/config.yaml"
      else if (cfg.nodeConfigFile != null) then cfg.nodeConfigFile
      else toFile "config-${toString cfg.nodeId}-${toString i}.json" (toJSON instanceConfig);
    topology = if cfg.topology != null then cfg.topology else toFile "topology.yaml" (toJSON {
      Producers = cfg.producers ++ (cfg.instanceProducers i);
    });
    consensusParams = {
      RealPBFT = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
      ];
      TPraos = [
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
      Cardano = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
    };
    instanceDbPath = "${cfg.databasePath}${optionalString (i > 0) "-${toString i}"}";
    exec = "cardano-node run";
        cmd = builtins.filter (x: x != "") [
          "${cfg.package}/bin/${exec}"
          "--config ${realNodeConfigFile}"
          "--database-path ${instanceDbPath}"
          "--topology ${topology}"
        ] ++ (lib.optionals (!cfg.systemdSocketActivation) [
          "--host-addr ${cfg.hostAddr}"
          "--port ${toString cfg.port}"
          "--socket-path ${cfg.socketPath}"
        ])
          ++ consensusParams.${cfg.nodeConfig.Protocol} ++ cfg.extraArgs ++ cfg.rtsArgs;
    in ''
        choice() { i=$1; shift; eval "echo \''${$((i + 1))}"; }
        echo "Starting ${exec}: ${concatStringsSep "\"\n   echo \"" cmd}"
        echo "..or, once again, in a single line:"
        echo "${toString cmd}"
        ${lib.optionalString (cfg.environment == "selfnode") ''
          echo "Wiping all data in ${cfg.stateDir}"
          rm -rf ${cfg.stateDir}/*
          GENESIS_FILE=$(${pkgs.jq}/bin/jq -r .GenesisFile < ${cfg.nodeConfigFile})
          START_TIME=$(date +%s --date="30 seconds")
          ${pkgs.jq}/bin/jq -r --arg startTime "''${START_TIME}" '. + {startTime: $startTime|tonumber}' < $GENESIS_FILE > ${cfg.stateDir}/genesis.json
          ${pkgs.jq}/bin/jq -r --arg GenesisFile genesis.json '. + {GenesisFile: $GenesisFile}' < ${cfg.nodeConfigFile} > ${realNodeConfigFile}
        ''}
        ${lib.optionalString (cfg.environment == "shelley_selfnode") ''
          echo "Wiping all data in ${cfg.stateDir}"
          rm -rf ${cfg.stateDir}/*
          GENESIS_FILE=$(${pkgs.jq}/bin/jq -r .GenesisFile < ${cfg.nodeConfigFile})
          START_TIME=$(date --utc +"%Y-%m-%dT%H:%M:%SZ" --date="30 seconds")
          ${pkgs.jq}/bin/jq -r --arg startTime "''${START_TIME}" '. + {startTime: $startTime}' < $GENESIS_FILE > ${cfg.stateDir}/genesis.json
          ${pkgs.jq}/bin/jq -r --arg GenesisFile genesis.json '. + {GenesisFile: $GenesisFile}' < ${cfg.nodeConfigFile} > ${realNodeConfigFile}
        ''}
        # If exist copy state from existing instance instead of syncing from scratch:
        if [[ (! -d ${instanceDbPath}) && (-d ${cfg.databasePath}) ]]; then
          cp -a ${cfg.databasePath} ${instanceDbPath}
        fi
        exec ${toString cmd}'';
in {
  options = {
    services.cardano-node = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable cardano-node, a node implementing ouroboros protocols
          (the blockchain protocols running cardano).
        '';
      };
      instanced = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable systemd service instancing.
          For details see https://fedoramagazine.org/systemd-template-unit-files/
        '';
      };
      instances = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Number of instance of the service to run.
        '';
      };
      script = mkOption {
        type = types.str;
        default = mkScript cfg 0;
      };

      profiling = mkOption {
        type = types.enum ["none" "time" "space" "space-module" "space-closure" "space-type" "space-retainer" "space-bio"];
        default = "none";
      };

      eventlog = mkOption {
        type = types.bool;
        default = false;
      };

      asserts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use an executable with asserts enabled.
        '';
      };

      cardanoNodePkgs = mkOption {
        type = types.attrs;
        default = import ../. {};
        defaultText = "cardano-node pkgs";
        description = ''
          The cardano-node packages and library that should be used.
          Main usage is sharing optimization:
          reduce eval time when service is instantiated multiple times.
        '';
      };

      package = mkOption {
        type = types.package;
        default = if (cfg.profiling != "none")
          then cardano-node-profiled
          else if cfg.eventlog then cardano-node-eventlogged
          else if cfg.asserts then cardano-node-asserted
          else cardano-node;
        defaultText = "cardano-node";
        description = ''
          The cardano-node package that should be used
        '';
      };

      environments = mkOption {
        type = types.attrs;
        default = commonLib.environments;
        description = ''
          environment node will connect to
        '';
      };

      environment = mkOption {
        type = types.enum (builtins.attrNames cfg.environments);
        default = "testnet";
        description = ''
          environment node will connect to
        '';
      };

     # TODO: remove
     genesisFile = mkOption {
        type = types.path;
        default = envConfig.genesisFile or null;
        description = ''
          Genesis json file
        '';
      };

     # TODO: remove
      genesisHash = mkOption {
        type = types.nullOr types.str;
        default = envConfig.genesisHash;
        description = ''
          Hash of the genesis file
        '';
      };

     # TODO: remove
      genesisHashPath = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to the Hash of the genesis file
        '';
      };

      # Byron signing/delegation

      signingKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      delegationCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Delegation certificate
        '';
      };

      # Shelley kes/vrf keys and operation cert

      kesKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };
      vrfKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      operationalCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Operational certificate
        '';
      };

      hostAddr = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          The host address to bind to
        '';
      };

      stateDir = mkOption {
        type = types.str;
        default = "/var/lib/cardano-node";
        description = ''
          Directory to store blockchain data.
        '';
      };

      runtimeDir = mkOption {
        type = types.nullOr types.str;
        default = "cardano-node";
        description = ''
          Runtime directory relative to /run
        '';
      };

      databasePath = mkOption {
        type = types.str;
        default = "${cfg.stateDir}/${cfg.dbPrefix}";
        description = ''Node database path.'';
      };

      socketPath = mkOption {
        type = types.str;
        default = "${runtimeDir}/node.socket";
        description = ''Local communication socket path.'';
      };

      systemdSocketActivation = mkOption {
        type = types.bool;
        default = false;
        description = ''Use systemd socket activation'';
      };

      extraServiceConfig = mkOption {
        # activate type for nixos-21.03:
        # type = types.functionTo (types.listOf types.attrs);
        default = n: i: {};
        description = ''
          Extra systemd service config, given service name and instance index.
        '';
      };

      extraSocketConfig = mkOption {
        # activate type for nixos-21.03:
        # type = types.functionTo (types.listOf types.attrs);
        default = n: i: {};
        description = ''
          Extra systemd socket config, given socket name and instance index.
        '';
      };

      dbPrefix = mkOption {
        type = types.str;
        default = "db-${cfg.environment}";
        description = ''
          Prefix of database directories inside `stateDir`.
          (eg. for "db", there will be db-0, etc.).
        '';
      };

      port = mkOption {
        type = types.either types.int types.str;
        default = 3001;
        description = ''
          The port number
        '';
      };

      nodeId = mkOption {
        type = types.int;
        default = 0;
        description = ''
          The ID for this node
        '';
      };

      producers = mkOption {
        default = [{
          addr = envConfig.relaysNew;
          port = envConfig.edgePort;
          valency = 1;
        }];
        type = types.listOf types.attrs;
        description = ''Static routes to peers.'';
      };

      instanceProducers = mkOption {
        # activate type for nixos-21.03:
        # type = types.functionTo (types.listOf types.attrs);
        default = _: [];
        description = ''
          Static routes to peers, specific to a given instance (when multiple instances are used)
        '';
      };

      topology = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Cluster topology. If not set `producers` array is used to generated topology file.
        '';
      };

      nodeConfig = mkOption {
        type = types.attrs;
        default = envConfig.nodeConfig;
        description = ''Internal representation of the config.'';
      };

      nodeConfigFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''Actual configuration file (shell expression).'';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''Extra CLI args for 'cardano-node'.'';
      };

      rtsArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        apply = args: if (args != [] || cfg.profilingArgs != []) then
          ["+RTS"] ++ cfg.profilingArgs ++ args ++ ["-RTS"]
          else [];
        description = ''Extra CLI args for 'cardano-node', to be surrounded by "+RTS"/"-RTS"'';
      };

      profilingArgs = mkOption {
        type = types.listOf types.str;
        default = let commonProfilingArgs = ["--machine-readable" "-tcardano-node.stats" "-pocardano-node"]
          ++ lib.optional (cfg.eventlog) "-l";
          in if cfg.profiling == "time" then ["-P"] ++ commonProfilingArgs
            else if cfg.profiling == "space" then ["-h"] ++ commonProfilingArgs
            else if cfg.profiling == "space-module" then ["-hm"] ++ commonProfilingArgs
            else if cfg.profiling == "space-closure" then ["-hd"] ++ commonProfilingArgs
            else if cfg.profiling == "space-type" then ["-hy"] ++ commonProfilingArgs
            else if cfg.profiling == "space-retainer" then ["-hr"] ++ commonProfilingArgs
            else if cfg.profiling == "space-bio" then ["-hb"] ++ commonProfilingArgs
            else [];
        description = ''RTS profiling options'';
      };

      tracingVerbosity = mkOption {
        type = types.str;
        default = envConfig.tracingVerbosity;
        description = ''verbosity level of structured representation of traced values.'';
      };

      protover-major = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      protover-minor = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      protover-alt = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
    };
  };

  config = mkIf cfg.enable ( let
    stateDirBase = "/var/lib/";
    genInstanceConf = f: listToAttrs (if cfg.instances > 1 && !cfg.instanced
      then genList (i: let n = "${systemdServiceName}-${toString i}"; in nameValuePair n (f n i)) cfg.instances
      else [ (nameValuePair systemdServiceName (f systemdServiceName 0)) ]); in {
    users.groups.cardano-node.gid = 10016;
    users.users.cardano-node = {
      description = "cardano-node node daemon user";
      uid = 10016;
      group = "cardano-node";
    };

    ## TODO:  use http://hackage.haskell.org/package/systemd for:
    ##   1. only declaring success after we perform meaningful init (local state recovery)
    ##   2. heartbeat & watchdog functionality
    systemd.services = genInstanceConf (n: i: recursiveUpdate ({
      description   = "cardano-node node ${toString i} service";
      after         = [ "network-online.target" ]
        ++ lib.optional cfg.systemdSocketActivation "${n}.socket";
      requires = lib.mkIf cfg.systemdSocketActivation [ "${n}.socket" ];
      wants = [ "network-online.target" ];
      script = mkScript cfg i;
      serviceConfig = {
        User = "cardano-node";
        Group = "cardano-node";
        Restart = "always";
        RuntimeDirectory = cfg.runtimeDir;
        WorkingDirectory = cfg.stateDir;
        # This assumes /var/lib/ is a prefix of cfg.stateDir.
        # This is checked as an assertion below.
        StateDirectory =  lib.removePrefix stateDirBase cfg.stateDir;
        NonBlocking = lib.mkIf cfg.systemdSocketActivation true;
        # time to sleep before restarting a service
        RestartSec = 1;
        KillSignal = "SIGINT";
      };
    } // optionalAttrs (!cfg.instanced && cfg.instances == 1) {
      wantedBy = [ "multi-user.target" ];
    } // optionalAttrs (cfg.instances > 1) {
      partOf = ["cardano-node.service"];
      requires = ["cardano-node.service"];
    }) (cfg.extraServiceConfig n i));

    systemd.sockets = genInstanceConf (n: i: lib.mkIf cfg.systemdSocketActivation (recursiveUpdate {
      description = "Socket of the ${n} service.";
      wantedBy = [ "sockets.target" ];
      partOf = [ "${n}.service" ];
      socketConfig = {
        ListenStream = [ "${cfg.hostAddr}:${toString cfg.port}" ]
          ++ [(if (i == 0) then cfg.socketPath else "${runtimeDir}/node-${toString i}.socket")];
        ReusePort = "yes";
        SocketMode = "0660";
        SocketUser = "cardano-node";
        SocketGroup = "cardano-node";
      };
    } (cfg.extraSocketConfig n i)));

    assertions = [
      {
        assertion = lib.hasPrefix stateDirBase cfg.stateDir;
        message = "The option services.cardano-node.stateDir should have ${stateDirBase} as a prefix!";
      }
      {
        assertion = (cfg.kesKey == null) == (cfg.vrfKey == null) && (cfg.kesKey == null) == (cfg.operationalCertificate == null);
        message = "Shelley Era: all of three [operationalCertificate kesKey vrfKey] options must be defined (or none of them).";
      }
    ];
  } // optionalAttrs (cfg.instances > 1) ( let instances = genList (i: "cardano-node-${toString i}.service") cfg.instances; in  {
    # oneshot service start allows to easily control all instances at once.
    systemd.services.cardano-node = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "cardano-node";
        Group = "cardano-node";
        ExecStart = "${pkgs.coreutils}/bin/echo Starting ${toString cfg.instances} cardano-node instances";
        RuntimeDirectory = cfg.runtimeDir;
        WorkingDirectory = cfg.stateDir;
        StateDirectory =  lib.removePrefix stateDirBase cfg.stateDir;;
      };
    };
  }));
}
