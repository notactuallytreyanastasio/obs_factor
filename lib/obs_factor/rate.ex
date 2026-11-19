defmodule ObsFactor.Rate do
  @moduledoc """
  Per-second rates from two readings of a monotonic counter.

  A counter that went backwards was reset (a restart): the rate for that
  interval is unknown, `nil`, never a negative number and never the whole
  counter divided by the interval (a spike).
  """

  def per_second(nil, _cur, _dt_s), do: nil
  def per_second(_prev, nil, _dt_s), do: nil
  def per_second(_prev, _cur, dt_s) when dt_s <= 0, do: nil
  def per_second(prev, cur, _dt_s) when cur < prev, do: nil
  def per_second(prev, cur, dt_s), do: (cur - prev) / dt_s
end
