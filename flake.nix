{
  description = "heads flake, mostly for devshell for now";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    flake-utils,
    nixpkgs,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      deps = with pkgs;
        [
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
          imagemagick
          innoextract
          libtool
          m4
          ncurses5 # make menuconfig and slang
          parted
          patch
          perl
          pkg-config
          python3
          rsync
          sharutils
          texinfo
          unzip
          wget
          which
          xz
          zip
          zlib-ng
        ]
        ++ [
          # blobs/xx30/vbios_[tw]530.sh
          bundler
          p7zip
          ruby
          sudo # ( °-° )
          upx
        ]
        ++ [
          # debugging/fixing/testing
          qemu
          vim
        ];
    in {
      devShell = pkgs.mkShellNoCC {
        buildInputs = deps;
      };
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
            ${self.devShell.${system}} >$out
        '';
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

            grep \
              -e NIX_CC_WRAPPER_TARGET_TARGET \
              -e NIX_CFLAGS_COMPILE_FOR_TARGET \
              -e NIX_LDFLAGS_FOR_TARGET \
              -e NIX_PKG_CONFIG_WRAPPER_TARGET \
              -e PKG_CONFIG_PATH_FOR_TARGET \
              ${self.devShell.${system}} >/devenv.sh

            printf '[safe]\n\tdirectory = *\n' >/.gitconfig
            mkdir /tmp;
          '';
      };
    });
}
