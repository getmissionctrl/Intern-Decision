{
  description = "Intern-Decision: self-hosted System-1 decision server (HF inference backend), nixified";

  inputs = {
    # nixos-unstable ships transformers >= 5.x, which the qwen3_5 architecture
    # requires — the release/pinned nixpkgs (transformers 4.51) cannot load the
    # model. Consumers dedupe by pointing inputs.nixpkgs.follows at their own
    # nixpkgs-unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      perSystem = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true; # torch-bin bundles CUDA (unfree)
              # torch-bin ships its own bundled CUDA runtime, so nixpkgs' own
              # (older) cudaPackages version is irrelevant to what actually runs.
              # Downgrade the version-mismatch guard from "broken" to a warning.
              problems.handlers.torch.unsupported-cuda-version = "warn";
            };
          };
          internDecision = pkgs.callPackage ./nix/package.nix { src = self; };
        in
        {
          packages.default = internDecision.serve;
          packages.intern-decision-serve = internDecision.serve;
          packages.intern-decision-pyenv = internDecision.pythonEnv;

          apps.default = { type = "app"; program = "${internDecision.serve}/bin/intern-decision-serve"; };
          apps.serve = { type = "app"; program = "${internDecision.serve}/bin/intern-decision-serve"; };

          devShells.default = pkgs.mkShell {
            packages = [ internDecision.pythonEnv ];
            shellHook = ''
              export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
              export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              echo "intern-decision dev shell — python $(python --version 2>&1 | cut -d' ' -f2), torch $(python -c 'import torch; print(torch.__version__)' 2>/dev/null), transformers $(python -c 'import transformers; print(transformers.__version__)' 2>/dev/null)"
              echo "run:  MODEL_CHECKPOINT=/path/to/ckpt uvicorn src.service.app:app --port 8100"
            '';
          };
        });
    in
    perSystem // {
      # The serving env must be built against THIS flake's nixpkgs (unstable), not
      # the host's — hosts inject their own (pinned) pkgs, whose transformers is
      # too old. So the module defaults its package to the flake's own build.
      # The `pkgs` in the pattern makes the module system hand pkgs to the module
      # file (which uses it for writeText/writeShellScript). But index self.packages
      # by a FIXED system, never the consumer's pkgs.system: forcing consumer pkgs
      # while resolving the imports list re-enters the NixOS module fixpoint
      # (infinite recursion) in models that don't pin pkgs via specialArgs
      # (e.g. cachix-deploy-lib.nixos). All target hosts are x86_64-linux.
      nixosModules.default = { pkgs, ... }@args: import ./nix/intern-decision-serve.nix (args // {
        defaultPackage = self.packages.x86_64-linux.intern-decision-serve;
      });
    };
}
