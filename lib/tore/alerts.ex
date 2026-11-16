defmodule Tore.Alerts do
  require Logger
  import Swoosh.Email

  alias Tore.Mailer

  @from {"Tore", "tore@rydholm.dev"}
  @to "gustaf.rydholm@gmail.com"

  def scrape_zero_results(url, chain) do
    send_alert(
      "[Tore] Scrape returned 0 deals — parser may be broken",
      "Chain: #{chain}\nURL: #{url}\n\nCheck the ICA parser — the page structure may have changed."
    )
  end

  @doc "Fetching a store's offers failed. It isn't retried until the next scheduled fetch."
  def scrape_failed(url, reason) do
    send_alert(
      "[Tore] Couldn't fetch a store's offers",
      "URL: #{url}\nReason: #{inspect(reason)}\n\nDeals stop updating until this is fixed."
    )
  end

  defp send_alert(subject, body) do
    new()
    |> to(@to)
    |> from(@from)
    |> subject(subject)
    |> text_body(body)
    |> Mailer.deliver()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("alert email not sent: #{inspect(reason)}")
    end
  end
end
