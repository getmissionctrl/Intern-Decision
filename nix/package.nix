# The Intern-Decision python env + a `intern-decision-serve` runner, built from
# whatever `pkgs` is in scope. Factored out so both the flake's packages AND the
# NixOS module build it the same way.
#
# `src` is the repo root (the flake's `self`); it goes on PYTHONPATH and is the
# cwd, so `src.service.app` resolves as a PEP 420 namespace package (the repo has
# no top-level `src/__init__.py`, exactly as the pip/venv workflow ran it).
{ lib, src, python3, fetchurl, writeShellApplication }:
let
  # nixpkgs-unstable ships the torch-bin 2.13.0+cu130 wheel, but only carries
  # cudaPackages 12.9 (SONAMEs .so.12) — so auto-patchelf cannot satisfy the cu130
  # wheel's CUDA-13 libs (.so.13) and the build fails outright. PyTorch also
  # publishes a +cu126 wheel of the same version, whose CUDA-12 libs DO match
  # nixpkgs' 12.9, and CUDA 12.6 runs on hq's existing 570 driver (no bump). So
  # retarget both wheels to their cu126 build. dontCheckRuntimeDeps drops the
  # redundant bundled-CUDA pypi metadata check.
  python = python3.override {
    packageOverrides = _pyfinal: pyprev: {
      # nixpkgs patches triton's libcuda_dirs() to hardcode NixOS's driver path,
      # but returns the string '/run/opengl-driver/lib/libcuda.so' where
      # library_dirs() does `[libdevice_dir, *libcuda_dirs()]` — the splat
      # explodes the string into per-character -L flags and the runtime kernel
      # compile fails. Return a proper single-element list of the DIR instead.
      triton = pyprev.triton.overridePythonAttrs (o: {
        postInstall = (o.postInstall or "") + ''
          for f in "$out"/lib/python*/site-packages/triton/backends/nvidia/driver.py; do
            substituteInPlace "$f" \
              --replace-fail "return '/run/opengl-driver/lib/libcuda.so'" \
                             "return ['/run/opengl-driver/lib']"
          done
        '';
      });
      torch-bin = pyprev.torch-bin.overridePythonAttrs (_: {
        src = fetchurl {
          name = "torch-2.13.0+cu126-cp314-cp314-manylinux_2_28_x86_64.whl";
          url = "https://download.pytorch.org/whl/cu126/torch-2.13.0%2Bcu126-cp314-cp314-manylinux_2_28_x86_64.whl";
          hash = "sha256-r/07SaTkiu+JX/2eGWGBvVBUItfDe0pvmvp2iZ0qzT0=";
        };
        dontCheckRuntimeDeps = true;
      });
      torchvision-bin = pyprev.torchvision-bin.overridePythonAttrs (_: {
        src = fetchurl {
          name = "torchvision-0.28.0+cu126-cp314-cp314-manylinux_2_28_x86_64.whl";
          url = "https://download.pytorch.org/whl/cu126/torchvision-0.28.0%2Bcu126-cp314-cp314-manylinux_2_28_x86_64.whl";
          hash = "sha256-SgoZHJIyWhE2YsrXWdluTpby/PTyDRad6ceTMQjuUME=";
        };
        dontCheckRuntimeDeps = true;
      });
    };
  };
  pythonEnv = python.withPackages (ps: with ps; [
    torch-bin          # prebuilt CUDA wheel (cu130) — no source build
    torchvision-bin    # Qwen3VL* processors import torchvision at load time
    transformers       # must be >= 5.x for the qwen3_5 architecture
    safetensors
    huggingface-hub
    pillow
    numpy
    fastapi
    uvicorn
    httpx
    pydantic
    python-dotenv
  ]);
in
{
  inherit pythonEnv;

  serve = writeShellApplication {
    name = "intern-decision-serve";
    runtimeInputs = [ pythonEnv ];
    text = ''
      export PYTHONPATH="${src}''${PYTHONPATH:+:$PYTHONPATH}"
      # torch-bin's bundled CUDA needs the host driver's libcuda.so.1 /
      # libnvidia-ml.so, which NixOS exposes here (a no-op on CPU-only hosts).
      export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      cd ${src}
      exec uvicorn src.service.app:app \
        --host "''${HOST:-0.0.0.0}" --port "''${PORT:-8100}" "$@"
    '';
  };
}
