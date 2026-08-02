defmodule CapAlertWorkbench.Cap.AreaCodes do
  @moduledoc """
  Stable registry of administrative area codes. Codes are kept as strings so
  that they round-trip through XML and JSON without coercion surprises.
  """

  @codes %{
    "440000" => "广东省",
    "440100" => "广州市",
    "440200" => "韶关市",
    "440300" => "深圳市",
    "440400" => "珠海市",
    "440500" => "汕头市",
    "440600" => "佛山市",
    "440700" => "江门市",
    "440800" => "湛江市",
    "440900" => "茂名市",
    "441200" => "肇庆市",
    "441300" => "惠州市",
    "441400" => "梅州市",
    "441500" => "汕尾市",
    "441600" => "河源市",
    "441700" => "阳江市",
    "441800" => "清远市",
    "441900" => "东莞市",
    "442000" => "中山市",
    "445100" => "潮州市",
    "445200" => "揭阳市",
    "445300" => "云浮市"
  }

  def all, do: @codes

  def description(code) when is_binary(code), do: Map.get(@codes, code)

  def valid?(code) when is_binary(code), do: Map.has_key?(@codes, code)

  def validate_codes(codes) when is_list(codes) do
    Enum.reduce_while(codes, :ok, fn code, :ok ->
      if valid?(code), do: {:cont, :ok}, else: {:halt, {:error, {:invalid_area_code, code}}}
    end)
  end
end
