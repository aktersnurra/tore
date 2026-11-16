defmodule ToreWeb.Dates do
  @moduledoc "Dates as the screens write them, in the household's language."

  use Gettext, backend: ToreWeb.Gettext

  @doc "The weekday written out: \"Wednesday\"."
  @spec weekday(Date.t()) :: String.t()
  def weekday(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> gettext("Monday")
      2 -> gettext("Tuesday")
      3 -> gettext("Wednesday")
      4 -> gettext("Thursday")
      5 -> gettext("Friday")
      6 -> gettext("Saturday")
      7 -> gettext("Sunday")
    end
  end

  @doc "The weekday as an owner, before a noun: \"Wednesday's\" (\"onsdagens\")."
  @spec weekday_possessive(Date.t()) :: String.t()
  def weekday_possessive(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> gettext("Monday's")
      2 -> gettext("Tuesday's")
      3 -> gettext("Wednesday's")
      4 -> gettext("Thursday's")
      5 -> gettext("Friday's")
      6 -> gettext("Saturday's")
      7 -> gettext("Sunday's")
    end
  end

  @doc "\"Wednesday 11 November\"."
  @spec long(Date.t()) :: String.t()
  def long(%Date{} = date), do: "#{weekday(date)} #{date.day} #{month(date)}"

  @doc "\"3 November\"."
  @spec day(Date.t()) :: String.t()
  def day(%Date{} = date), do: "#{date.day} #{month(date)}"

  @doc "A week as \"9–15 November\", or \"30 November – 6 December\" across two months."
  @spec range(Date.t(), Date.t()) :: String.t()
  def range(%Date{month: m} = from, %Date{month: m} = to),
    do: "#{from.day}–#{to.day} #{month(to)}"

  def range(%Date{} = from, %Date{} = to),
    do: "#{from.day} #{month(from)} – #{to.day} #{month(to)}"

  defp month(%Date{month: month}) do
    case month do
      1 -> gettext("January")
      2 -> gettext("February")
      3 -> gettext("March")
      4 -> gettext("April")
      5 -> gettext("May")
      6 -> gettext("June")
      7 -> gettext("July")
      8 -> gettext("August")
      9 -> gettext("September")
      10 -> gettext("October")
      11 -> gettext("November")
      12 -> gettext("December")
    end
  end
end
