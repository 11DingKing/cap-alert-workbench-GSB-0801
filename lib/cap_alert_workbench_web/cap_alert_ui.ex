defmodule CapAlertWorkbenchWeb.CapAlertUI do
  @moduledoc "Presentation helpers for CAP workflow states and enums."
  alias CapAlertWorkbench.CapAlert.Enums

  def workflow_badge(state) do
    {text, class} =
      case state do
        :draft -> {"草稿", "bg-slate-100 text-slate-700 ring-slate-200"}
        :in_review -> {"待复核", "bg-amber-50 text-amber-700 ring-amber-200"}
        :changes_requested -> {"需修改", "bg-orange-50 text-orange-700 ring-orange-200"}
        :approved -> {"已通过复核", "bg-sky-50 text-sky-700 ring-sky-200"}
        :published -> {"已发布", "bg-emerald-50 text-emerald-700 ring-emerald-200"}
        :superseded -> {"已被更正", "bg-slate-100 text-slate-500 ring-slate-200"}
        :cancelled -> {"已解除", "bg-rose-50 text-rose-700 ring-rose-200"}
        :withdrawn -> {"已撤回", "bg-slate-100 text-slate-500 ring-slate-200"}
        other -> {inspect(other), "bg-slate-100 text-slate-700 ring-slate-200"}
      end

    {text,
     "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inspect " <>
       class}
  end

  def cap_severity_badge(severity) do
    {text, class} =
      case severity do
        :extreme -> {"Extreme 极端", "bg-rose-600 text-white"}
        :severe -> {"Severe 严重", "bg-red-500 text-white"}
        :moderate -> {"Moderate 中等", "bg-amber-500 text-white"}
        :minor -> {"Minor 较小", "bg-yellow-400 text-slate-900"}
        :unknown -> {"Unknown 未知", "bg-slate-300 text-slate-700"}
        _ -> {inspect(severity), "bg-slate-300 text-slate-700"}
      end

    {text, "inline-flex items-center rounded px-2 py-0.5 text-xs font-semibold " <> class}
  end

  def outbox_badge(:pending), do: {"待发送", "bg-amber-50 text-amber-700 ring-amber-200"}
  def outbox_badge(:published), do: {"已发送", "bg-emerald-50 text-emerald-700 ring-emerald-200"}
  def outbox_badge(:failed), do: {"失败", "bg-rose-50 text-rose-700 ring-rose-200"}

  def enum_options(module, list_func) do
    list_func = if is_atom(list_func), do: list_func, else: list_func
    values = apply(module, list_func, [])

    Enum.map(values, fn atom ->
      {Enums.workflow_state_string(atom), Atom.to_string(atom)}
    end)
  end

  def select_options(atoms, label_func) do
    Enum.map(atoms, fn a -> {label_func.(a), Atom.to_string(a)} end)
  end

  def format_sent(nil), do: "—"

  def format_sent(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  def format_sent(other), do: to_string(other)

  def geocodes_summary(geocodes) when is_list(geocodes) do
    geocodes
    |> Enum.map(fn gc -> "#{gc.value_name}:#{gc.value}" end)
    |> Enum.join(", ")
  end

  def geocodes_summary(_), do: ""
end
