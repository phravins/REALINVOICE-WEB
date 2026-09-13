defmodule RealinvoiceCloudWeb.Format do
  @moduledoc """
  Display formatting for billing data.

  Imported into every template by `RealinvoiceCloudWeb.html_helpers/0`.
  """

  @doc """
  Formats an amount as rupees, grouped the Indian way.

  Digits are grouped in a final block of three and then in pairs, so
  1234567.5 reads as `₹12,34,567.50` rather than `₹1,234,567.50`.

      iex> money(Decimal.new("57230.00"))
      "₹57,230.00"

      iex> money(Decimal.new("1234567.5"))
      "₹12,34,567.50"

      iex> money(nil)
      "—"
  """
  def money(nil), do: "—"

  def money(%Decimal{} = amount) do
    negative? = Decimal.negative?(amount)

    [rupees, paise] =
      amount
      |> Decimal.abs()
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> String.split(".")

    sign = if negative?, do: "-", else: ""

    "#{sign}₹#{group_indian(rupees)}.#{paise}"
  end

  # An empty SUM() comes back as a plain 0 rather than a decimal.
  def money(amount) when is_integer(amount), do: amount |> Decimal.new() |> money()

  @doc """
  Formats a quantity without trailing zeros: `2`, not `2.000`.
  """
  def qty(nil), do: "—"

  def qty(%Decimal{} = quantity) do
    rounded = Decimal.round(quantity, 3)

    if Decimal.equal?(rounded, Decimal.round(rounded, 0)) do
      rounded |> Decimal.round(0) |> Decimal.to_string(:normal)
    else
      rounded |> Decimal.normalize() |> Decimal.to_string(:normal)
    end
  end

  @doc """
  Formats a tax rate as a percentage without trailing zeros: `18%`.
  """
  def percent(nil), do: "—"
  def percent(%Decimal{} = rate), do: qty(rate) <> "%"

  @doc """
  Formats a date as `13 Sep 2026`.
  """
  def date(nil), do: "—"
  def date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")

  @doc """
  Formats a UTC timestamp as `13 Sep 2026, 15:37 UTC`.
  """
  def datetime(nil), do: "—"
  def datetime(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  # The last three digits form one group; everything above them is grouped in
  # pairs (the lakh/crore convention).
  defp group_indian(digits) do
    case String.length(digits) do
      n when n <= 3 ->
        digits

      n ->
        {head, tail} = String.split_at(digits, n - 3)

        head
        |> String.reverse()
        |> String.to_charlist()
        |> Enum.chunk_every(2)
        |> Enum.map_join(",", &to_string/1)
        |> String.reverse()
        |> Kernel.<>("," <> tail)
    end
  end
end
