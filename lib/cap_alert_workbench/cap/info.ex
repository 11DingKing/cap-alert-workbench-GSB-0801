defmodule CapAlertWorkbench.Cap.Info do
  @moduledoc """
  CAP `<info>` 段的结构化表示。

  一条 CAP 预警可携带多个 info 段，每段有自己的 severity/urgency/certainty、
  headline/description 以及 area（geocode 集合），用于表达
  「440800 维持 Severe、440900 升级 Extreme」这类分地区预警。
  未识别的子元素保留在 `extensions` 中保证 round-trip。
  """

  alias CapAlertWorkbench.Cap.Enums
  alias CapAlertWorkbench.Cap.Xml.Element

  defstruct language: "zh-CN",
            category: :met,
            event: nil,
            urgency: :immediate,
            severity: :severe,
            certainty: :likely,
            headline: nil,
            description: nil,
            instruction: nil,
            effective: nil,
            expires: nil,
            areas: [],
            extensions: []

  @type geocode :: %{value_name: String.t(), value: String.t()}
  @type area :: %{area_desc: String.t() | nil, geocodes: [geocode()]}

  @type t :: %__MODULE__{
          language: String.t(),
          category: atom(),
          event: String.t() | nil,
          urgency: atom(),
          severity: atom(),
          certainty: atom(),
          headline: String.t() | nil,
          description: String.t() | nil,
          instruction: String.t() | nil,
          effective: String.t() | nil,
          expires: String.t() | nil,
          areas: [area()],
          extensions: [Element.t()]
        }

  @scalar_fields [
    :language,
    :event,
    :headline,
    :description,
    :instruction,
    :effective,
    :expires
  ]

  @enum_fields [:category, :urgency, :severity, :certainty]

  @doc "info -> jsonb 纯 map（枚举显式映射为 CAP 字符串）。"
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = info) do
    scalars = Map.new(@scalar_fields, fn f -> {Atom.to_string(f), Map.get(info, f)} end)

    enums =
      Map.new(@enum_fields, fn f -> {Atom.to_string(f), Enums.to_cap(f, Map.get(info, f))} end)

    scalars
    |> Map.merge(enums)
    |> Map.put("areas", Enum.map(info.areas, &area_to_map/1))
    |> Map.put("extensions", Enum.map(info.extensions, &Element.to_map/1))
  end

  @doc "jsonb map -> info（枚举严格映射）。"
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    Enum.reduce_while(@enum_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Enums.from_cap(field, Map.fetch!(map, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, enums} ->
        {:ok,
         struct!(
           __MODULE__,
           Map.merge(
             %{
               language: map["language"] || "zh-CN",
               event: map["event"],
               headline: map["headline"],
               description: map["description"],
               instruction: map["instruction"],
               effective: map["effective"],
               expires: map["expires"],
               areas:
                 Enum.map(map["areas"] || [], fn area ->
                   %{
                     area_desc: area["area_desc"],
                     geocodes:
                       Enum.map(area["geocodes"] || [], fn gc ->
                         %{value_name: gc["value_name"], value: gc["value"]}
                       end)
                   }
                 end),
               extensions: Enum.map(map["extensions"] || [], &Element.from_map/1)
             },
             enums
           )
         )}

      error ->
        error
    end
  end

  @doc "该 info 段覆盖的全部 geocode 编码。"
  @spec geocodes(t()) :: [String.t()]
  def geocodes(%__MODULE__{} = info) do
    Enum.flat_map(info.areas, fn area -> Enum.map(area.geocodes, & &1.value) end)
  end

  defp area_to_map(area) do
    %{
      "area_desc" => Map.get(area, :area_desc) || Map.get(area, "area_desc"),
      "geocodes" =>
        Enum.map(Map.get(area, :geocodes) || Map.get(area, "geocodes") || [], fn gc ->
          %{
            "value_name" => Map.get(gc, :value_name) || Map.get(gc, "value_name"),
            "value" => Map.get(gc, :value) || Map.get(gc, "value")
          }
        end)
    }
  end
end
