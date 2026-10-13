{ lib, pkgs, ... }:
let
  # nixpkgs' helix.runtime only ships grammars + queries, because upstream helix
  # 25.07 embeds the themes and the tutor in the binary. steelix forks an older
  # helix that still reads both from disk, but reuses helix.runtime as-is -- so
  # every theme fails to load. Re-wrap it against a runtime dir that has them.
  runtime = pkgs.runCommand "steelix-runtime" { } ''
    mkdir -p $out
    ln -s ${pkgs.helix.runtime}/grammars $out/grammars
    ln -s ${pkgs.helix.runtime}/queries $out/queries
    ln -s ${pkgs.steelix.src}/runtime/themes $out/themes
    ln -s ${pkgs.steelix.src}/runtime/tutor $out/tutor
  '';

  steelix = pkgs.symlinkJoin {
    name = "steelix-${pkgs.steelix.version}";
    paths = [ pkgs.steelix ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    postBuild = ''
      rm $out/bin/hx
      makeBinaryWrapper ${pkgs.steelix}/bin/.hx-wrapped $out/bin/hx \
        --inherit-argv0 \
        --set HELIX_RUNTIME ${runtime}
    '';
    inherit (pkgs.steelix) meta;
  };
in
{
  programs.helix = {
    enable = true;
    defaultEditor = true;
    package = steelix;
    extraPackages = [ pkgs.nil ];
    settings = {
      theme = "kaolin-valley-dark";
      keys.normal = {
        R = ":reset-diff-change";
      };
    };
    languages.language = [
      {
        name = "nix";
        auto-format = true;
        formatter = {
          command = lib.getExe pkgs.nixfmt;
          # bare `nixfmt` is deprecated for stdin, `-` is the explicit spelling
          args = [ "-" ];
        };
      }
    ];
  };
}
