{ pkgs, config, ... }:

{
  languages.elixir.enable = true;

  env.MIX_HOME = "${config.env.DEVENV_STATE}/mix";
  env.HEX_HOME = "${config.env.DEVENV_STATE}/hex";

  git-hooks.hooks = {
    mix-format = {
      enable = true;
      excludes = [ "^example/" ];
    };
  };

  enterTest = ''
    mix deps.get
    mix test
  '';
}
