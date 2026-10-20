defmodule Mix.Tasks.Compile.ExPcieNif do
  @moduledoc """
  Builds the vfio NIF (`c_src/ex_pcie_nif.c`) with `make` when `make` and a
  C compiler exist. The NIF is optional: a failed or skipped build only
  logs a notice, and `ExPcie.Device` falls back to the `:mock` and `:sysfs`
  backends.
  """
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    if System.find_executable("make") &&
         (System.find_executable("cc") || System.find_executable("gcc")) do
      priv = Path.join(Mix.Project.app_path(), "priv")

      case System.cmd("make", ["-s", "PRIV_DIR=#{priv}", "ERTS_INCLUDE_DIR=#{erts_include()}"],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          {:ok, []}

        {out, _} ->
          Mix.shell().info("ex_pcie: NIF not built (optional):\n#{out}")
          {:noop, []}
      end
    else
      Mix.shell().info("ex_pcie: no make/cc, NIF skipped (optional)")
      {:noop, []}
    end
  end

  defp erts_include,
    do:
      Path.join([
        List.to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "include"
      ])
end
