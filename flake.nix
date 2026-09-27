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
      # Inject the flake's own serving package (built against unstable — the
      # qwen3_5 arch needs transformers 5.x) as a module arg. This is a plain
      # attrset-module, NOT a function wrapper doing `args // {...}`: capturing and
      # re-merging the whole module-args set forces its full spine, which re-enters
      # the NixOS module fixpoint (infinite recursion) under models that don't pin
      # pkgs via specialArgs (e.g. cachix-deploy-lib.nixos). Index self.packages by
      # a fixed system for the same reason — all target hosts are x86_64-linux.
      nixosModules.default = {
        imports = [
          { _module.args.internDecisionPackage = self.packages.x86_64-linux.intern-decision-serve; }
          ./nix/intern-decision-serve.nix
        ];
      };
    };
}
