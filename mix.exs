defmodule VerifiedTranslations.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/onnimonni/verified_translations"

  def project do
    [
      app: :verified_translations,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Compile-time verified Gettext translations for Phoenix via the ~t sigil. " <>
          "Fails compilation when a translation is missing for any locale.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gettext, "~> 0.26 or ~> 1.0"},
      {:expo, "~> 0.5 or ~> 1.0"},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end
