{
  description = "Jekyll GitHub Pages local build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
      in {
        apps.default = let
          jekyll-serve = pkgs.writeShellApplication {
            name = "jekyll-serve";
            runtimeInputs = [
              pkgs.ruby
              pkgs.bundler
              pkgs.gnumake
              pkgs.gcc
              pkgs.pkg-config
              pkgs.zlib
              pkgs.libffi
            ];
            text = ''
              set -e

              export GEM_HOME="$PWD/.gem"
              export BUNDLE_PATH="$GEM_HOME"
              export BUNDLE_BIN="$PWD/.bundle/bin"
              export PATH="$BUNDLE_BIN:$GEM_HOME/bin:$PATH"

              bundle install

              bundle exec jekyll serve --livereload &
              JEKYLL_PID=$!

              sleep 1

              xdg-open http://localhost:4000 || true

              wait $JEKYLL_PID
            '';
          };
        in {
          type = "app";
          program = "${jekyll-serve}/bin/jekyll-serve";
        };
      }
    );
}
