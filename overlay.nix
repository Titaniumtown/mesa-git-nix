final: prev:
let
  lib = prev.lib;
  versionInfo = builtins.fromJSON (builtins.readFile ./version.json);
  rustDeps = lib.importJSON ./wraps.json;

  # libdrm-git — tracks gitlab.freedesktop.org/mesa/drm main branch.
  # mesa-git links against this instead of nixpkgs' libdrm so both
  # stay in lockstep with the kernel DRM subsystem.
  libdrmVersionInfo = builtins.fromJSON (builtins.readFile ./libdrm-version.json);

  mkLibdrmGit =
    drm:
    drm.overrideAttrs (old: {
      version = "${libdrmVersionInfo.version}-${builtins.substring 0 7 libdrmVersionInfo.rev}";
      src = prev.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "mesa";
        repo = "drm";
        inherit (libdrmVersionInfo) rev hash;
      };
    });

  libdrm-git = mkLibdrmGit prev.libdrm;

  # 32-bit libdrm-git (only evaluates on x86_64-linux where pkgsi686Linux exists)
  libdrm-git-32 = mkLibdrmGit prev.pkgsi686Linux.libdrm;

  # Build the Rust crate package cache from our wraps.json
  fetchDep =
    dep:
    prev.fetchCrate {
      inherit (dep) pname version hash;
      unpack = false;
    };

  toCommand = dep: "ln -s ${dep} $out/${dep.pname}-${dep.version}.tar.gz";

  packageCacheCommand = lib.pipe rustDeps [
    (map fetchDep)
    (map toCommand)
    (lib.concatStringsSep "\n")
  ];

  packageCache = prev.runCommand "mesa-git-rust-package-cache" { } ''
    mkdir -p $out
    ${packageCacheCommand}
  '';

  # ===========================================================================
  # Driver presets — vendor-specific + common essentials
  # ===========================================================================
  #
  # Common drivers are always included regardless of vendor selection:
  #   - llvmpipe/softpipe: software renderers (fallback, CI, headless)
  #   - zink: OpenGL-over-Vulkan (compatibility layer)
  #   - virgl: virtio-gpu for VMs
  #   - swrast (vulkan): Lavapipe software Vulkan
  #   - virtio (vulkan): virtio-gpu native context for VMs
  #
  commonGallium = [
    "llvmpipe"
    "softpipe"
    "zink"
    "virgl"
  ];
  commonVulkan = [
    "swrast"
    "virtio"
  ];

  vendorGallium = {
    amd = [
      "radeonsi"
      "r600"
      "r300"
    ];
    intel = [
      "iris"
      "crocus"
      "i915"
    ];
    nvidia = [
      "nouveau"
      "tegra"
    ];
  };

  vendorVulkan = {
    amd = [ "amd" ];
    intel = [
      "intel"
      "intel_hasvk"
    ];
    nvidia = [ "nouveau" ];
  };

  # Resolve a list of vendor names into deduplicated driver lists
  resolveDrivers =
    vendors:
    let
      gallium = lib.unique (commonGallium ++ lib.concatMap (v: vendorGallium.${v} or [ ]) vendors);
      vulkan = lib.unique (commonVulkan ++ lib.concatMap (v: vendorVulkan.${v} or [ ]) vendors);
    in
    {
      inherit gallium vulkan;
    };

  # ===========================================================================
  # Core override — applies git source + patches to any mesa derivation
  # ===========================================================================
  mesaGitOverride =
    baseMesa:
    {
      galliumDrivers ? null,
      vulkanDrivers ? null,
      libdrm ? libdrm-git,
    }:
    let
      # libdrm (and the rest of mesa's build closure) is inherited from nixpkgs,
      # which keeps it in lockstep with mesa. Per-arch is automatic:
      # pkgsi686Linux.mesa already carries the 32-bit libdrm.
      mesa = baseMesa;

      # Determine the effective gallium driver list for output/postInstall decisions
      effectiveGallium = if galliumDrivers != null then galliumDrivers else mesa.galliumDrivers or [ ];

      # d3d12 produces spirv2dxil; asahi/panfrost produce cross_tools binaries.
      # When using default drivers (nixpkgs list), assume all outputs are built.
      # When using custom drivers, only enable outputs for actually-selected drivers.
      # Note: d3d12 is excluded from default builds (unreliable on git main).
      hasD3d12 = galliumDrivers != null && builtins.elem "d3d12" effectiveGallium;
      hasAsahi = builtins.elem "asahi" effectiveGallium;
      hasPanfrost = builtins.elem "panfrost" effectiveGallium;
      hasCrossToolDrivers =
        if galliumDrivers != null then (hasAsahi || hasPanfrost) else true;

      # Replace driver flags in mesonFlags if custom lists are provided
      overrideDriverFlags =
        flags:
        let
          isDriverFlag = f: lib.hasPrefix "-Dgallium-drivers=" f || lib.hasPrefix "-Dvulkan-drivers=" f;
          filtered = builtins.filter (f: !isDriverFlag f) flags;
        in
        filtered
        ++ lib.optional (galliumDrivers != null) (
          lib.mesonOption "gallium-drivers" (lib.concatStringsSep "," galliumDrivers)
        )
        ++ lib.optional (vulkanDrivers != null) (
          lib.mesonOption "vulkan-drivers" (lib.concatStringsSep "," vulkanDrivers)
        );

      # Filter outputs: remove spirv2dxil/cross_tools when their drivers aren't built
      filterOutputs =
        outputs:
        builtins.filter (
          o: (o != "spirv2dxil" || hasD3d12) && (o != "cross_tools" || hasCrossToolDrivers)
        ) outputs;

      # Filter mesonFlags: remove tool/compiler flags when cross_tools drivers aren't built
      filterMesonFlags =
        flags:
        if hasCrossToolDrivers then
          flags
        else
          builtins.filter (
            f:
            !(lib.hasPrefix "-Dtools=" f)
            && !(lib.hasPrefix "-Dinstall-mesa-clc=" f)
            && !(lib.hasPrefix "-Dinstall-precomp-compiler=" f)
          ) flags;

    in
    mesa.overrideAttrs (old: {
      version = "${versionInfo.version}-${builtins.substring 0 7 versionInfo.rev}";

      src = prev.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "mesa";
        repo = "mesa";
        inherit (versionInfo) rev hash;
      };

      # nixpkgs' opencl.patch targets specific line numbers that won't match git main.
      # The underlying changes (clang-libdir option, rusticl ICD install disable) are
      # handled: clang-libdir is passed via mesonFlags, and the ICD path is reconstructed
      # in postInstall. We reapply just the functional parts via postPatch.
      patches = [ ];

      postPatch = ''
        patchShebangs .

        # Replicate opencl.patch effect: use clang-libdir meson option instead of llvm query.
        # If the string is present, replace it. If absent, fail loudly so the
        # maintainer can investigate and update the postPatch.
        if grep -qF "dep_llvm.get_variable(cmake : 'LLVM_LIBRARY_DIR'" meson.build; then
          substituteInPlace meson.build \
            --replace-fail "dep_llvm.get_variable(cmake : 'LLVM_LIBRARY_DIR', configtool: 'libdir')" \
                           "get_option('clang-libdir')"
        else
          echo "ERROR: clang-libdir pattern not found in meson.build — Mesa may have refactored the build system."
          echo "The overlay postPatch must be updated. Check upstream meson.build for the new clang libdir logic."
          exit 1
        fi

        # Add clang-libdir meson option definition, guarding against missing trailing newline
        if ! grep -qF "clang-libdir" meson.options; then
          printf '\n' >> meson.options
          cat ${./clang-libdir-option.meson} >> meson.options
        fi
        # Disable rusticl ICD file auto-install (nixpkgs constructs its own with absolute path).
        if [ -f src/gallium/targets/rusticl/meson.build ]; then
          if grep -qF "install : true" src/gallium/targets/rusticl/meson.build; then
            sed -i '/configure_file/,/^)/{s/install : true/install : false/}' \
              src/gallium/targets/rusticl/meson.build
            if grep -qF "install : true" src/gallium/targets/rusticl/meson.build; then
              echo "WARNING: rusticl ICD install : true may not have been fully replaced"
            fi
          fi
        fi
      '';

      # Remove outputs that won't be populated with the selected drivers
      outputs = filterOutputs (old.outputs or [ "out" ]);

      mesonFlags = filterMesonFlags (overrideDriverFlags (old.mesonFlags or [ ]));

      env = (old.env or { }) // {
        MESON_PACKAGE_CACHE_DIR = packageCache;
      };

      meta = (old.meta or { }) // {
        description = "Mesa (git main) - bleeding-edge 3D graphics library";
      };
    });

in
{
  # Default: all drivers (same as nixpkgs)
  mesa-git = mesaGitOverride prev.mesa { };
  mesa-git-32 = mesaGitOverride prev.pkgsi686Linux.mesa {
    libdrm = libdrm-git-32;
  };

  # Build mesa-git with only the specified vendor drivers + common essentials.
  #
  # Usage:
  #   pkgs.mkMesaGit { vendors = [ "amd" ]; }
  #   pkgs.mkMesaGit { vendors = [ "amd" "intel" ]; }  # iGPU + dGPU
  #   pkgs.mkMesaGit { galliumDrivers = [ "radeonsi" "llvmpipe" ]; vulkanDrivers = [ "amd" ]; }
  #
  mkMesaGit =
    {
      vendors ? [ ],
      galliumDrivers ? null,
      vulkanDrivers ? null,
    }:
    let
      resolved = resolveDrivers vendors;
      gd =
        if galliumDrivers != null then
          galliumDrivers
        else if vendors != [ ] then
          resolved.gallium
        else
          null;
      vd =
        if vulkanDrivers != null then
          vulkanDrivers
        else if vendors != [ ] then
          resolved.vulkan
        else
          null;
    in
    mesaGitOverride prev.mesa {
      galliumDrivers = gd;
      vulkanDrivers = vd;
    };

  mkMesaGit32 =
    {
      vendors ? [ ],
      galliumDrivers ? null,
      vulkanDrivers ? null,
    }:
    let
      resolved = resolveDrivers vendors;
      gd =
        if galliumDrivers != null then
          galliumDrivers
        else if vendors != [ ] then
          resolved.gallium
        else
          null;
      vd =
        if vulkanDrivers != null then
          vulkanDrivers
        else if vendors != [ ] then
          resolved.vulkan
        else
          null;
    in
    mesaGitOverride prev.pkgsi686Linux.mesa {
      galliumDrivers = gd;
      vulkanDrivers = vd;
      libdrm = libdrm-git-32;
    };
  # Companion libdrm-git (tracks same upstream repo, same pin)
  inherit libdrm-git libdrm-git-32;
  # Globally override libdrm so Xwayland/gamescope/mesa all share the same ABI
  libdrm = libdrm-git;

  # Expose presets and resolver for downstream modules
  mesa-git-lib = {
    inherit
      vendorGallium
      vendorVulkan
      commonGallium
      commonVulkan
      resolveDrivers
      ;
  };
}
