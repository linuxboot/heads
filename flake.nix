{
  description = "Optimized heads flake for Docker image with garbage collection protection";

  # Inputs define external dependencies and their sources.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; # Using the unstable channel for the latest packages, while flake.lock fixates the commit reused until changed.
    flake-utils.url = "github:numtide/flake-utils"; # Utilities for flake functionality.
  };

  # Outputs are the result of the flake, including the development environment and Docker image.
  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system}; # Accessing the legacy package set.
      lib = pkgs.lib; # The standard Nix packages library.

      # Dependencies are the packages required for the Heads project.
      # Organized into subsets for clarity and maintainability.
      deps = with pkgs; [
        # Core build utilities
        autoconf
        automake
        bashInteractive
        coreutils
        bc
        bison # Generate flashmap descriptor parser
        bzip2
        cacert
        ccache
        cmake
        cpio
        curl
        diffutils
        dtc
        e2fsprogs
        elfutils
        findutils
        flex
        gawk
        git
        gnat
        gnugrep
        gnumake
        gnused
        gnutar
        gzip
        imagemagick # For bootsplash manipulation.
        innoextract # ROM extraction for dGPU.
        libtool
        m4
        ncurses5 # make menuconfig and slang
        openssl #needed for talos-2 kernel build
        parted
        patch
        perl
        pkg-config
        python3 # me_cleaner, coreboot.
        rsync # coreboot.
        sharutils
        texinfo
        unzip
        wget
        which
        xz
        zip
        zlib
        zlib.dev
      ] ++ [
        # Packages for qemu support with Canokey integration.
        qemu # To test make BOARD=qemu-coreboot-* boards and then call make BOARD=qemu-coreboot-* with inject_gpg statement, and then run statement (RTFM).
        #canokey doesn;t work still even if compiled in, so no reason to add 1Gb of stuff in the image
        #canokey-qemu # Canokey lib for qemu build-time compilation.
        #(qemu.override {
        #  canokeySupport = true; # This override enables Canokey support in QEMU, resulting in -device canokey being available.
        #})
      ] ++ [
        # Additional tools for debugging/editing/testing.
        vim # Mostly used amongst us, sorry if you'd like something else, open issue.
        swtpm # QEMU requirement to emulate tpm1/tpm2.
        dosfstools # QEMU requirement to produce valid fs to store exported public key to be fused through inject_key on qemu (so qemu flashrom emulated SPI support).
      ] ++ [
        # Tools for handling binary blobs in their compressed state. (blobs/xx30/vbios_[tw]530.sh)
        bundler
        p7zip
        ruby
        sudo # ( °-° )
        upx
      ];

      # Stripping binaries to reduce size, while ensuring functionality is not affected.
      stripBinaries = map (pkg: if pkg?isDerivation then pkg.overrideAttrs (oldAttrs: {
        postInstall = oldAttrs.postInstall or "" + ''
          strip $out/bin/* || true
        '';
      }) else pkg) deps;

    in {
      # The development shell includes all the dependencies.
      devShell = pkgs.mkShellNoCC {
        buildInputs = stripBinaries ++ [ pkgs.nix ]; # Include the Nix package to provide nix-collect-garbage.
        shellHook = ''
          # Create a garbage collection root for the Nix profile
          mkdir -p /nix/var/nix/gcroots/per-user/$(whoami)
          echo $(readlink -f $HOME/.nix-profile) > /nix/var/nix/gcroots/per-user/$(whoami)/profile
          # Perform garbage collection to clean up any unnecessary files.
          nix-collect-garbage -d
        '';
      };

      # myDevShell outputs environment variables necessary for development.
      packages.myDevShell =
        pkgs.runCommand "my-dev-shell" {}
        #bash
        ''
          grep \
            -e CMAKE_PREFIX_PATH \
            -e NIX_CC_WRAPPER_TARGET_TARGET \
            -e NIX_CFLAGS_COMPILE_FOR_TARGET \
            -e NIX_LDFLAGS_FOR_TARGET \
            -e PKG_CONFIG_PATH_FOR_TARGET \
            -e ACLOCAL_PATH \
            ${self.devShell.${system}} >$out
        '';

      # Docker image configuration for the Heads project.
      packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
        name = "linuxboot/heads"; # Image name.
        tag = "dev-env"; # Image tag.
        config.Entrypoint = ["bash" "-c" ''source /devenv.sh; if (( $# == 0 )); then exec bash; else exec "$0" "$@"; fi'']; # Entrypoint configuration.
        
        # Contents of the Docker image, including stripped binaries for size optimization.
        contents = stripBinaries ++ [
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.usrBinEnv
        ];
        
        enableFakechroot = true; # Enable fakechroot for compatibility.
        
        # Fake root commands to set up the environment inside the Docker image.
        fakeRootCommands =
          #bash
          ''
          set -e

          # Environment setup for the development shell.
          grep \
            -e NIX_CC_WRAPPER_TARGET_TARGET \
            -e NIX_CFLAGS_COMPILE_FOR_TARGET \
            -e NIX_LDFLAGS_FOR_TARGET \
            -e NIX_PKG_CONFIG_WRAPPER_TARGET \
            -e PKG_CONFIG_PATH_FOR_TARGET \
            -e ACLOCAL_PATH \
            ${self.devShell.${system}} >/devenv.sh

          # Git configuration for safe directory access.
          printf '[safe]\n\tdirectory = *\n' >/.gitconfig
          mkdir /tmp; # Temporary directory for various operations.
        '';
      };
    });
}

