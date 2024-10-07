{
  description = "Optimized heads flake for Docker image with garbage collection protection";

  # Inputs define external dependencies and their sources.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; # Using the unstable channel for the latest packages, while flake.lock fixates the commit reused until changed.
    flake-utils.url = "github:numtide/flake-utils"; # Utilities for flake functionality.
  };
  # Outputs are the result of the flake, including the development environment and Docker image.
  outputs = {
    self,
    flake-utils,
    nixpkgs,
    ...
  }:
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
        gnat # required for libgfxinit under coreboot, hacked around for kgpe-d16
        gnugrep
        gnumake
        gnused
        gnutar
        gzip
        imagemagick # For bootsplash manipulation
        innoextract # ROM extraction for dGPU
        libtool
        m4
        ncurses5 # make menuconfig and slang
        nss
        openssl # needed for talos-2 kernel build
        parted
        patch
        perl
        pkg-config
        python3 # me_cleaner, coreboot
        rsync # coreboot
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
        qemu_full #Heavier then qemu + qemu_kvm, but contains qemu-img + kvm and everything else needed to do development/testing cycles under docker
      ] ++ [
        # Additional tools for debugging/editing/testing
        vim # Mostly used amongst us, sorry if you'd like something else, open issue
        swtpm # QEMU requirement to emulate tpm1/tpm2
        dosfstools # QEMU requirement to produce valid fs to store exported public key to be fused through inject_key on qemu (so qemu flashrom emulated SPI support).
        diffoscopeMinimal # Not sure exactly what is packed here, let's try. Might need diffoscope if something is missing
        gnupg #to inject public key inside of qemu create rom through inject_gpg target of targets/qemu.mk TODO: remove when pflash supported by flashrom + modify code
        less # so 'git log' is usable
        moreutils # so that 'make 2>&1 | ts' can give timestamps
      ] ++ [
        # Tools for handling binary blobs in their compressed state. (blobs/xx30/vbios_[tw]530.sh)
        bundler
        p7zip
        ruby
        sudo # ( °-° )
        upx
        binwalk # Extract all components of a binary
        uefi-firmware-parser #Parse and extract further hidden UEFI blobs from binaries
      ];
    in {
      # The development shell includes all the dependencies.
      devShell = pkgs.mkShellNoCC {
        buildInputs = deps;
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
        name = "linuxboot/heads";
        tag = "dev-env";
        config.Entrypoint = ["bash" "-c" ''source /devenv.sh; if (( $# == 0 )); then exec bash; else exec "$0" "$@"; fi''];
        contents =
          deps
          ++ [
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.usrBinEnv
        ];
        enableFakechroot = true;
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

          # Ensure /etc/passwd and /etc/group exist with root entries
          echo "root:x:0:0:root:/root:/bin/bash" > /etc/passwd
          echo "root:x:0:" > /etc/group
          mkdir -p /root
          chmod 700 /root
        '';
      };
    });
}
