defmodule Mix.Tasks.VerifiedTranslations.Put do
  @shortdoc "Adds or updates translations of a message"
  @moduledoc """
  Writes translations into the message's JSON file, creating it when needed.

      mix verified_translations.put "Hello %{name}" fi="Hei %{name}" sv="Hej %{name}"
      mix verified_translations.put --domain admin "Settings" fi=Asetukset
      mix verified_translations.put --from translations.json

  `--from` reads a JSON array of objects shaped like the message files:

      [{"msgid": "Hello %{name}", "fi": "Hei %{name}"}, {"msgid": "Save", "fi": "Tallenna"}]

  Every locale must be configured and every `%{binding}` must appear in the
  msgid, so the result is guaranteed to pass compile-time verification for
  the given locales. Existing translations of other locales are kept. Run
  `mix verified_translations.missing` to see what is left.

  ## Options

    * `--domain` - message domain, default `"default"`
    * `--from` - JSON file with many messages (`-` reads stdin)
  """

  use Mix.Task

  alias VerifiedTranslations.{Compiler, Message}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadconfig")
    {opts, args} = OptionParser.parse!(argv, strict: [domain: :string, from: :string])
    config = Compiler.config()
    domain = Keyword.get(opts, :domain, config.domain)

    messages =
      case {opts[:from], args} do
        {nil, [msgid | pairs]} -> [{msgid, parse_pairs(pairs)}]
        {nil, []} -> Mix.raise(~s|usage: mix verified_translations.put "msgid" fi="..." sv="..."|)
        {from, []} -> read_batch(from)
        {_, _} -> Mix.raise("give either --from or a msgid with translations, not both")
      end

    errors = Enum.flat_map(messages, fn {msgid, t} -> validate(msgid, t, config) end)

    if errors != [] do
      Mix.raise("nothing written:\n" <> Enum.join(errors, "\n"))
    end

    Enum.each(messages, fn {msgid, translations} ->
      path = Message.path(config.path, domain, msgid)
      Message.update!(path, msgid, translations)
      Mix.shell().info("#{path}: #{translations |> Map.keys() |> Enum.sort() |> Enum.join(", ")}")
    end)
  end

  defp parse_pairs(pairs) do
    Map.new(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [locale, text] -> {locale, text}
        _ -> Mix.raise("expected locale=text, got: #{inspect(pair)}")
      end
    end)
  end

  defp read_batch(from) do
    content = if from == "-", do: IO.read(:stdio, :eof), else: File.read!(from)

    case JSON.decode(content) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn
          %{"msgid" => msgid} = data when is_binary(msgid) -> {msgid, Map.delete(data, "msgid")}
          other -> Mix.raise("each entry needs a \"msgid\", got: #{inspect(other)}")
        end)

      _ ->
        Mix.raise("#{from}: expected a JSON array of message objects")
    end
  end

  defp validate(msgid, translations, config) do
    allowed = Message.bindings(msgid)

    Enum.flat_map(translations, fn {locale, text} ->
      cond do
        locale not in config.locales ->
          [
            "#{inspect(msgid)}: #{inspect(locale)} is not in configured locales #{inspect(config.locales)}"
          ]

        not is_binary(text) ->
          ["#{inspect(msgid)}: #{locale} must be a string"]

        (unknown = Message.bindings(text) -- allowed) != [] ->
          [
            "#{inspect(msgid)}: #{locale} uses unknown #{Enum.map_join(unknown, ", ", &"%{#{&1}}")}"
          ]

        true ->
          []
      end
    end)
  end
end
