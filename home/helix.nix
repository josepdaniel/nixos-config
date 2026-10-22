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
  # nhx replaces programs.helix: same config.toml/languages.toml, plus Steel
  # plugins installed into STEEL_HOME and a generated init.scm.
  programs.nhx = {
    enable = true;
    package = steelix;
    settings = {
      theme = "monokai_pro";
      keys.normal = {
        R = ":reset-diff-change";
        # f = ":forest-open";
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
    steel.enable = true;
    plugins.forest = {
      enable = true;
      config.position = "left";
    };
  };

  home.sessionVariables.EDITOR = "hx";
  home.packages = [ pkgs.nil ];
}
