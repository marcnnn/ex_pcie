# :verilator - co-simulation and lint, needs verilator in PATH
# :yosys - synthesis, needs yosys in PATH
# :nif - the vfio NIF, only when it was built
exclude =
  [
    verilator: is_nil(System.find_executable("verilator")),
    yosys: is_nil(System.find_executable("yosys")),
    nif: not ExPcie.Nif.loaded?()
  ]
  |> Enum.filter(&elem(&1, 1))

ExUnit.start(exclude: exclude)
