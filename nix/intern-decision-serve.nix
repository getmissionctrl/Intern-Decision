# NixOS module: run the Intern-Decision decision server (its Jev-wire-compatible
# /v1/jev + /v1/decisions HTTP API) as a hardened systemd service with GPU access.
#
# `defaultPackage` is injected by the flake's `nixosModules.default` wrapper so the
# serving env is built against the flake's own (unstable) nixpkgs — the pinned
# host nixpkgs ships transformers 4.51, which cannot load the qwen3_5 architecture.
{ config, lib, pkgs, defaultPackage, ... }:
let
  cfg = config.services.intern-decision;

  # Device-appropriate inference config. The checkpoint path is supplied out of
  # band via MODEL_CHECKPOINT (it lives under the runtime StateDirectory), so it
  # is intentionally omitted here.
  inferenceConfig = pkgs.writeText "intern-decision-inference.json" (builtins.toJSON {
    backend = "hf";
    device = cfg.device;
    dtype = cfg.dtype;
    attn_implementation = cfg.attnImplementation;
    max_length = cfg.maxLength;
    thinking.enabled = false;
  });

  checkpointDir = "/var/lib/${cfg.stateDirectory}/checkpoint";

  # A tiny helper env just for the first-boot weight download. Host `pkgs` is fine
  # here: snapshot_download never loads the model, so it is agnostic to the
  # transformers version that the serving env pins.
  downloadPy = pkgs.python3.withPackages (ps: [ ps.huggingface-hub ]);

  downloadScript = pkgs.writeShellScript "intern-decision-download" ''
    set -eu
    if [ -f "${checkpointDir}/config.json" ]; then
      echo "checkpoint already present at ${checkpointDir}"
      exit 0
    fi
    echo "downloading ${cfg.model} to ${checkpointDir} (first boot only) ..."
    ${downloadPy}/bin/huggingface-cli download "${cfg.model}" --local-dir "${checkpointDir}"
  '';
in
{
  options.services.intern-decision = {
    enable = lib.mkEnableOption "Intern-Decision System-1 decision server (Jev-wire-compatible HTTP API)";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "intern-decision.packages.\${system}.intern-decision-serve";
      description = ''
        The intern-decision-serve package to run. Defaults to the flake's own
        package, which is built against the flake's (unstable) nixpkgs so that
        transformers is new enough for the qwen3_5 architecture.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "internlm/Intern-Decision-4B";
      description = "Hugging Face repo id to download into the state directory on first boot.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to bind. Use 0.0.0.0 to serve the LAN/Tailscale net.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8100;
      description = "TCP port to listen on.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "cuda";
      example = "cpu";
      description = "torch device for inference (cuda, cpu, cuda:0, ...).";
    };

    dtype = lib.mkOption {
      type = lib.types.enum [ "bfloat16" "float16" "float32" ];
      default = "bfloat16";
      description = "Model dtype. Use float32 on CPU; bfloat16 on the GPU.";
    };

    attnImplementation = lib.mkOption {
      type = lib.types.enum [ "sdpa" "eager" "flash_attention_2" ];
      default = "sdpa";
      description = "Attention kernel. Use eager on CPU; sdpa on the GPU.";
    };

    maxLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Maximum input token length.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` in the firewall.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "intern-decision";
      description = "Name under /var/lib for the downloaded checkpoint and HF cache.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.intern-decision = {
      description = "Intern-Decision System-1 decision server (Jev-wire-compatible)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOST = cfg.host;
        PORT = toString cfg.port;
        INFERENCE_CONFIG = inferenceConfig;
        MODEL_CHECKPOINT = checkpointDir;
        HF_HOME = "/var/lib/${cfg.stateDirectory}/huggingface";
        # torch-bin bundles its own CUDA runtime but still needs the host
        # driver's libcuda.so.1 / libnvidia-ml.so, which NixOS exposes here.
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };

      serviceConfig = {
        ExecStartPre = downloadScript;
        ExecStart = "${cfg.package}/bin/intern-decision-serve";
        Restart = "on-failure";
        RestartSec = 5;
        # First boot downloads ~9 GB of weights before the server listens.
        TimeoutStartSec = "3600";

        DynamicUser = true;
        StateDirectory = cfg.stateDirectory;

        # GPU: keep the nvidia device nodes visible to the sandbox.
        PrivateDevices = false;
        DeviceAllow = lib.mkIf (lib.hasPrefix "cuda" cfg.device) [
          "/dev/nvidia0 rw"
          "/dev/nvidiactl rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia-modeset rw"
        ];

        # Hardening (kept compatible with CUDA device access).
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
