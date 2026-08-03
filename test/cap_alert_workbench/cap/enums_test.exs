defmodule CapAlertWorkbench.Cap.EnumsTest do
  use ExUnit.Case, async: true

  alias CapAlertWorkbench.Cap.Enums

  test "to_cap 显式映射全部枚举" do
    assert Enums.to_cap(:status, :actual) == "Actual"
    assert Enums.to_cap(:msg_type, :update) == "Update"
    assert Enums.to_cap(:msg_type, :cancel) == "Cancel"
    assert Enums.to_cap(:scope, :public) == "Public"
    assert Enums.to_cap(:urgency, :immediate) == "Immediate"
    assert Enums.to_cap(:severity, :severe) == "Severe"
    assert Enums.to_cap(:certainty, :likely) == "Likely"
    assert Enums.to_cap(:category, :met) == "Met"
  end

  test "from_cap 严格映射，未知值报错且不产生 atom" do
    assert {:ok, :actual} = Enums.from_cap(:status, "Actual")
    assert {:ok, :likely} = Enums.from_cap(:certainty, "Likely")
    assert {:error, {:unknown_enum, :severity, "Severe2"}} = Enums.from_cap(:severity, "Severe2")
    assert {:error, {:unknown_enum, :status, "actual"}} = Enums.from_cap(:status, "actual")
  end

  test "values 返回全部合法值" do
    assert :severe in Enums.values(:severity)
    assert length(Enums.values(:status)) == 5
  end
end
