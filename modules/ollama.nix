{ config, lib, pkgs, ... }:

let
  cfg      = config.services.ollamaLocal;
  ollamaPkg = pkgs.ollama-bin;
in
{
  options.services.ollamaLocal = {
    enable   = lib.mkEnableOption "Ollama local inference service";
    host     = lib.mkOption { type = lib.types.str;  default = "127.0.0.1"; };
    port     = lib.mkOption { type = lib.types.port; default = 11434; };
    endpoint = lib.mkOption {
      type     = lib.types.str;
      default  = "http://${cfg.host}:${toString cfg.port}";
      readOnly = true;
    };
    loadModels = lib.mkOption {
      type    = lib.types.listOf lib.types.str;
      default = [];
    };
    rocmGfxOverride = lib.mkOption {
      type    = lib.types.str;
      default = "";
      description = "Value for HSA_OVERRIDE_GFX_VERSION.";
    };
  };

  config = lib.mkIf cfg.enable {

    systemd.services.ollama = {
      description = "Ollama inference daemon";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" "sys-devices-virtual-dri.device" ];
      requires    = [ "sys-devices-virtual-dri.device" ];

      environment = {
        OLLAMA_HOST              = "${cfg.host}:${toString cfg.port}";
        LD_LIBRARY_PATH          = "${ollamaPkg}/lib/ollama/rocm";
      } // lib.optionalAttrs (cfg.rocmGfxOverride != "") {
        HSA_OVERRIDE_GFX_VERSION = cfg.rocmGfxOverride;
      };

      serviceConfig = {
        ExecStart        = "${ollamaPkg}/bin/ollama serve";
        Restart          = "on-failure";
        RestartSec       = "3s";
        User             = "ollama";
        Group            = "ollama";
        StateDirectory   = "ollama";
        WorkingDirectory = "/var/lib/ollama";
      };
    };

    systemd.services.ollama-load-models = lib.mkIf (cfg.loadModels != []) {
      description = "Pull configured Ollama models";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "ollama.service" ];
      requires    = [ "ollama.service" ];
      environment.OLLAMA_HOST = "http://${cfg.host}:${toString cfg.port}";
      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        User            = "ollama";
        ExecStartPre    = "${pkgs.coreutils}/bin/sleep 2";
        ExecStart       = map (m: "${ollamaPkg}/bin/ollama pull ${m}") cfg.loadModels;
      };
    };

    users.users.ollama  = {
      isSystemUser = true;
      group        = "ollama";
      home         = "/var/lib/ollama";
      extraGroups  = [ "render" "video" ];
    };
    users.groups.ollama = {};
  };
}