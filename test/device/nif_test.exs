defmodule ExPcie.Device.NifTest do
  use ExUnit.Case, async: true
  @moduletag :nif
  alias ExPcie.{Device, Nif}

  test "capabilities" do
    assert %{vfio: _, dma: true, eventfd: true, version: 1} = Nif.capabilities()
  end

  test "vfio open of a nonexistent device" do
    assert {:error, :enoent} = Nif.vfio_open("0000:ff:00.0")
    assert {:error, :enoent} = Device.open(:vfio, bdf: "0000:ff:00.0")
    assert_raise ArgumentError, fn -> Nif.vfio_open("../../x") end
  end

  test "mmap_file errors and BAR access" do
    assert {:error, :enoent} = Nif.mmap_file("/nonexistent/resource0", 0)
    path = Path.join(System.tmp_dir!(), "ex_pcie_nif_#{System.unique_integer([:positive])}")
    File.write!(path, :binary.copy(<<0>>, 64))
    on_exit(fn -> File.rm(path) end)
    {:ok, bar} = Nif.mmap_file(path, 0)
    assert 64 = Nif.bar_size(bar)
    assert :ok = Nif.bar_write32(bar, 4, 0xCAFEBABE)
    assert {:ok, 0xCAFEBABE} = Nif.bar_read32(bar, 4)
    assert {:error, :unaligned} = Nif.bar_read32(bar, 2)
    assert {:error, :out_of_bounds} = Nif.bar_read32(bar, 64)
    assert {:error, :out_of_bounds} = Nif.bar_read32(bar, 0xFFFF_FFFF_FFF8)
    assert {:error, :out_of_bounds} = Nif.bar_read(bar, 60, 8)
    assert {:error, :unaligned} = Nif.bar_write(bar, 0, <<1, 2, 3>>)
    assert :ok = Nif.bar_write(bar, 8, <<1, 2, 3, 4, 5, 6, 7, 8>>)
    assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8>>} = Nif.bar_read(bar, 8, 8)
    assert_raise ArgumentError, fn -> Nif.bar_write32(bar, 0, 0x1_0000_0000) end
    assert_raise ArgumentError, fn -> Nif.bar_read32(:nope, 0) end
  end

  test "DMA buffers without iommu" do
    {:ok, a, ia} = Nif.dma_alloc(:test_no_iommu, 5000, false)
    {:ok, b, ib} = Nif.dma_alloc(:test_no_iommu, 16, false)
    assert rem(ia, 4096) == 0 and rem(ib, 4096) == 0
    assert ib >= ia + 8192
    assert {^ia, 5000} = Nif.dma_info(a)
    assert {:ok, <<0, 0>>} = Nif.dma_read(a, 4998, 2)
    assert :ok = Nif.dma_write(a, 10, <<1, 2, 3>>)
    assert {:ok, <<1, 2, 3>>} = Nif.dma_read(a, 10, 3)
    assert {:error, :out_of_bounds} = Nif.dma_write(b, 15, <<1, 2>>)
    assert {:error, :out_of_bounds} = Nif.dma_read(b, 17, 0)
    assert :ok = Nif.dma_free(a)
    assert :ok = Nif.dma_free(a)
    assert {:error, :closed} = Nif.dma_read(a, 0, 1)
    assert {:error, :closed} = Nif.dma_write(a, 0, <<1>>)
    assert_raise ArgumentError, fn -> Nif.dma_alloc(:test_no_iommu, 0, false) end
    assert_raise ArgumentError, fn -> Nif.dma_alloc(:other, 16, false) end
  end

  test "eventfd delivery through enif_select" do
    {:ok, e} = Nif.eventfd_new(5)
    assert :ok = Nif.irq_subscribe(e, self(), :tag)
    refute_receive {:ex_pcie_irq, _, _}, 20
    :ok = Nif.eventfd_signal(e)
    assert_receive {:ex_pcie_irq, :tag, 5}
    # one-shot until acked
    :ok = Nif.eventfd_signal(e)
    refute_receive {:ex_pcie_irq, _, _}, 20
    assert {:ok, 2} = Nif.irq_ack(e)
    :ok = Nif.eventfd_signal(e)
    assert_receive {:ex_pcie_irq, :tag, 5}
    assert :ok = Nif.irq_unsubscribe(e)
    assert {:ok, 1} = Nif.irq_ack(e)
    :ok = Nif.eventfd_signal(e)
    refute_receive {:ex_pcie_irq, _, _}, 20
    assert :ok = Nif.eventfd_close(e)
    assert {:error, :closed} = Nif.eventfd_signal(e)
  end

  test "eventfd already signalled before subscribe, and close while armed" do
    {:ok, e} = Nif.eventfd_new(1)
    :ok = Nif.eventfd_signal(e)
    :ok = Nif.irq_subscribe(e, self(), {:t, 1})
    assert_receive {:ex_pcie_irq, {:t, 1}, 1}
    {:ok, 1} = Nif.irq_ack(e)
    assert :ok = Nif.eventfd_close(e)
    {:ok, e2} = Nif.eventfd_new(2)
    :ok = Nif.irq_subscribe(e2, self(), :x)
    assert :ok = Nif.eventfd_close(e2)
    :erlang.garbage_collect()
  end
end
