defmodule ExPcie.Device.SysfsTest do
  use ExUnit.Case, async: true
  alias ExPcie.Device

  @bdf "0000:03:00.0"

  setup do
    root = Path.join(System.tmp_dir!(), "ex_pcie_sysfs_#{System.unique_integer([:positive])}")
    dir = Path.join(root, @bdf)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "resource0"), :binary.copy(<<0>>, 256))
    File.write!(Path.join(dir, "resource2"), :binary.copy(<<0xAA>>, 16))
    File.write!(Path.join(dir, "resource4"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, dir: dir}
  end

  defp run_suite(root, dir, mmap) do
    {:ok, dev} = Device.open(:sysfs, bdf: @bdf, sysfs_root: root, mmap: mmap)
    assert {:ok, 256} = Device.bar_size(dev, 0)
    assert {:ok, 16} = Device.bar_size(dev, 2)
    assert {:error, :invalid_bar} = Device.bar_size(dev, 4)
    assert {:error, :invalid_bar} = Device.read32(dev, 1, 0)

    assert :ok = Device.write32(dev, 0, 0x10, 0x11223344)
    assert {:ok, 0x11223344} = Device.read32(dev, 0, 0x10)

    assert <<_::binary-size(16), 0x44, 0x33, 0x22, 0x11, _::binary>> =
             File.read!(Path.join(dir, "resource0"))

    assert {:ok, 0xAAAAAAAA} = Device.read32(dev, 2, 12)

    assert :ok = Device.write_bytes(dev, 0, 32, <<1, 2, 3, 4, 5, 6, 7, 8>>)
    assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8>>} = Device.read_bytes(dev, 0, 32, 8)

    assert {:error, :out_of_bounds} = Device.read32(dev, 0, 256)
    assert {:error, :out_of_bounds} = Device.write_bytes(dev, 2, 12, <<0::64>>)
    assert {:error, :unaligned} = Device.read32(dev, 0, 1)

    assert {:error, :unsupported} = Device.alloc_dma(dev, 4096)
    assert {:error, :unsupported} = Device.subscribe_irq(dev, 0)
    assert %{backend: :sysfs, bars: %{0 => 256, 2 => 16}} = Device.info(dev)
    assert :ok = Device.close(dev)
  end

  test("pread/pwrite fallback", %{root: root, dir: dir}, do: run_suite(root, dir, false))

  @tag :nif
  test "mmap through the NIF", %{root: root, dir: dir} do
    run_suite(root, dir, true)
    {:ok, dev} = Device.open(:sysfs, bdf: @bdf, sysfs_root: root)
    assert %{access: :mmap} = Device.info(dev)
  end

  test "errors", %{root: root} do
    assert {:error, :enoent} = Device.open(:sysfs, bdf: "0000:09:00.0", sysfs_root: root)
    assert {:error, :missing_bdf} = Device.open(:sysfs, sysfs_root: root)
    assert {:error, :invalid_bdf} = Device.open(:sysfs, bdf: "../etc", sysfs_root: root)
  end
end
