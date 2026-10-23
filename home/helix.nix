{ lib, pkgs, ... }:
let
  # claudix: review threads in Helix answered by the running Claude Code
  # session. Source lives in ./claudix (daemon, Steel cog, Claude skill) and
  # is installed from the store; edits need a rebuild.
  claudixSrc = ./claudix;
  claudixCog = pkgs.runCommandLocal "claudix-cog" { passthru.cogName = "claudix"; } ''
    mkdir -p $out
    cp ${claudixSrc}/helix/claudix.scm $out/
  '';
  claudixDaemon = "${claudixSrc}/daemon/claudix.ts";
  claudixUp = "${claudixSrc}/daemon/up.sh";
  claudixReply = "${claudixSrc}/daemon/reply.sh";
  # Languages reviewed with claudix. Each entry restates Helix's default
  # servers for that language, since language-servers replaces the default.
  claudixLanguages = {
    nix = [ "nixd" ];
    rust = [ "rust-analyzer" ];
    typescript = [ "typescript-language-server" ];
    tsx = [ "typescript-language-server" ];
    javascript = [ "typescript-language-server" ];
    jsx = [ "typescript-language-server" ];
    python = [
      "ty"
      "ruff"
      "jedi"
      "pylsp"
    ];
    go = [
      "gopls"
      "golangci-lint-lsp"
    ];
    bash = [ "bash-language-server" ];
    fish = [ "fish-lsp" ];
    toml = [
      "taplo"
      "tombi"
    ];
    yaml = [
      "yaml-language-server"
      "ansible-language-server"
    ];
    json = [ "vscode-json-language-server" ];
    markdown = [
      "marksman"
      "markdown-oxide"
      "rumdl"
    ];
    scheme = [ "steel-language-server" ];
  };

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
      # show claudix threads (and other diagnostics) inline, not only in the gutter
      editor.end-of-line-diagnostics = "hint";
      editor.inline-diagnostics.cursor-line = "hint";
      keys.normal = {
        R = ":reset-diff-change";
        f = ":forest-open";
      };
    };
    languages.language = [
      {
        name = "nix";
        language-servers = claudixLanguages.nix ++ [ "claudix" ];
        auto-format = true;
        formatter = {
          command = lib.getExe pkgs.nixfmt;
          # bare `nixfmt` is deprecated for stdin, `-` is the explicit spelling
          args = [ "-" ];
        };
      }
    ]
    ++ lib.mapAttrsToList (name: servers: {
      inherit name;
      language-servers = servers ++ [ "claudix" ];
    }) (removeAttrs claudixLanguages [ "nix" ]);
    # Helix spawns the shim; the shim connects to the daemon that /claudix
    # started in Claude Code for this project, or idles if there is none.
    languages.language-server.claudix = {
      command = lib.getExe pkgs.bun;
      args = [ "${claudixSrc}/daemon/shim.ts" ];
    };
    # nixd evaluates the real system so option completion, hover docs and
    # goto-definition work for options from flake inputs (nhx, home-manager),
    # which nil cannot see. First eval is slow; it is cached afterwards.
    languages.language-server.nixd =
      let
        flake = ''(builtins.getFlake "/etc/nixos")'';
      in
      {
        command = lib.getExe pkgs.nixd;
        config.nixd = {
          nixpkgs.expr = "import ${flake}.inputs.nixpkgs { }";
          options = {
            nixos.expr = "${flake}.nixosConfigurations.deep-thought.options";
            home-manager.expr = "${flake}.nixosConfigurations.deep-thought.options.home-manager.users.type.getSubOptions [ ]";
          };
        };
      };
    steel.enable = true;
    plugins.forest = {
      enable = true;
      config.position = "left";
    };
    plugins.claudix = {
      enable = true;
      package = claudixCog;
    };
  };

  # the /claudix Claude Code skill, with the daemon's store path filled in
  home.file.".claude/skills/claudix/SKILL.md".text =
    builtins.replaceStrings [ "@daemon@" "@up@" "@reply@" ] [ claudixDaemon claudixUp claudixReply ]
      (builtins.readFile "${claudixSrc}/skill/SKILL.md");

  home.sessionVariables.EDITOR = "hx";
  # Language servers for every language in claudixLanguages, so the lists
  # above resolve to real binaries. Helix skips any that are missing, so
  # trimming this is safe.
  home.packages = with pkgs; [
    nixd
    rust-analyzer
    typescript-language-server
    typescript
    ty
    ruff
    python3Packages.jedi-language-server
    python3Packages.python-lsp-server
    gopls
    golangci-lint-langserver
    golangci-lint
    bash-language-server
    shellcheck
    fish-lsp
    taplo
    tombi
    yaml-language-server
    ansible-language-server
    vscode-langservers-extracted
    marksman
    markdown-oxide
    rumdl
  ];
}
