defmodule VerifiedTranslations.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/onnimonni/verified_translations"

  def project do
    [
      app: :verified_translations,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Compile-time verified translations for Phoenix: ~t sigil, one JSON file per message, " <>
          "inlined at compile time, compilation fails when any locale is missing.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:expo, "~> 0.5 or ~> 1.0", optional: true},
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
