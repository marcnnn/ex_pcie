defmodule ExPcie.Device.MockTest do
  use ExUnit.Case, async: true
  alias ExPcie.Device
  alias ExPcie.Device.{DmaBuffer, Mock}

  defp open(opts \\ []) do
    {:ok, dev} = Device.open(:mock, opts)
    on_exit(fn -> Device.close(dev) end)
    dev
  end

  test "BAR read/write and defaults" do
    dev = open(bars: %{0 => 4096, 2 => 64})
    assert {:ok, 0} = Device.read32(dev, 0, 0)
    assert :ok = Device.write32(dev, 0, 8, 0xDEADBEEF)
    assert {:ok, 0xDEADBEEF} = Device.read32(dev, 0, 8)
    assert {:ok, 4096} = Device.bar_size(dev, 0)
    assert {:ok, 64} = Device.bar_size(dev, 2)
    assert {:error, :invalid_bar} = Device.bar_size(dev, 1)
    assert {:error, :invalid_bar} = Device.read32(dev, 1, 0)
    assert {:error, :invalid_bar} = Device.read32(dev, 6, 0)
  end

  test "default BAR0 is 1 MiB" do
    assert {:ok, 1_048_576} = Device.bar_size(open(), 0)
  end

  test "bounds, alignment and value checks" do
    dev = open(bars: %{0 => 64})
    assert {:error, :unaligned} = Device.read32(dev, 0, 2)
    assert {:error, :unaligned} = Device.write32(dev, 0, 1, 0)
    assert {:error, :out_of_bounds} = Device.read32(dev, 0, 64)
    assert {:ok, _} = Device.read32(dev, 0, 60)
    assert {:error, :invalid_value} = Device.write32(dev, 0, 0, 0x1_0000_0000)
    assert {:error, :invalid_value} = Device.write32(dev, 0, 0, -1)
    assert {:error, :unaligned} = Device.read_bytes(dev, 0, 0, 6)
    assert {:error, :out_of_bounds} = Device.read_bytes(dev, 0, 60, 8)
    assert {:error, :out_of_bounds} = Device.write_bytes(dev, 0, 60, <<0::64>>)
  end

  test "byte ranges use little-endian 32-bit words" do
    dev = open(bars: %{0 => 64})
    assert :ok = Device.write_bytes(dev, 0, 4, <<1, 2, 3, 4, 5, 6, 7, 8>>)
    assert {:ok, 0x04030201} = Device.read32(dev, 0, 4)
    assert {:ok, 0x08070605} = Device.read32(dev, 0, 8)
    assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8>>} = Device.read_bytes(dev, 0, 4, 8)
    assert {:ok, <<>>} = Device.read_bytes(dev, 0, 4, 0)
  end

  test "hooks" do
    test = self()

    dev =
      open(
        bars: %{0 => 64},
        on_read: fn
          0, 0x10 -> 42
          _, _ -> :default
        end,
        on_write: fn bar, off, v ->
          send(test, {:w, bar, off, v})
          :ok
        end
      )

    assert {:ok, 42} = Device.read32(dev, 0, 0x10)
    assert {:ok, 0} = Device.read32(dev, 0, 0x14)
    :ok = Device.write32(dev, 0, 0x14, 7)
    assert_receive {:w, 0, 0x14, 7}
    assert {:ok, 7} = Device.read32(dev, 0, 0x14)
    {:ok, <<42::32-little, 7::32-little>>} = Device.read_bytes(dev, 0, 0x10, 8)
  end

  test "hook may call back into the mock" do
    {:ok, dev} =
      Device.open(:mock,
        bars: %{0 => 64},
        on_write: fn _, _, v -> send(self(), {:seen, v}) end
      )

    :ok = Device.write32(dev, 0, 0, 5)
    assert_received {:seen, 5}
  end

  test "DMA alloc, IOVA non-overlap, read/write, translate" do
    dev = open()
    {:ok, %DmaBuffer{iova: a, size: 5000} = ba} = Device.alloc_dma(dev, 5000)
    {:ok, %DmaBuffer{iova: b} = bb} = Device.alloc_dma(dev, 16)
    assert rem(a, 4096) == 0 and rem(b, 4096) == 0
    assert a >= 0x1_0000_0000
    assert b >= a + 8192

    assert {:ok, <<0, 0, 0, 0>>} = Device.dma_read(dev, ba, 100, 4)
    assert :ok = Device.dma_write(dev, ba, 100, <<1, 2, 3, 4>>)
    assert {:ok, <<1, 2, 3, 4>>} = Device.dma_read(dev, ba, 100, 4)
    assert {:ok, <<0, 1, 2, 3, 4, 0>>} = Device.dma_read(dev, ba, 99, 6)
    assert {:error, :out_of_bounds} = Device.dma_write(dev, bb, 14, <<1, 2, 3>>)
    assert {:error, :out_of_bounds} = Device.dma_read(dev, bb, 0, 17)

    assert {:ok, ^ba, 100} = Mock.dma_translate(dev, a + 100, 4)
    assert {:ok, ^bb, 0} = Mock.dma_translate(dev, b, 16)
    assert :error = Mock.dma_translate(dev, b, 17)
    assert :error = Mock.dma_translate(dev, a + 4999, 2)
    assert :error = Mock.dma_translate(dev, a + 6000, 1)

    assert :ok = Mock.dma_write_iova(dev, a + 8, <<9, 9>>)
    assert {:ok, <<9, 9>>} = Mock.dma_read_iova(dev, a + 8, 2)
    assert {:ok, <<9, 9>>} = Device.dma_read(dev, ba, 8, 2)
    assert {:error, :unmapped} = Mock.dma_read_iova(dev, 0x42, 4)
    assert {:error, :unmapped} = Mock.dma_write_iova(dev, b + 10, <<0::64>>)

    assert :ok = Device.free_dma(dev, ba)
    assert {:error, :unmapped} = Mock.dma_read_iova(dev, a, 4)
    assert {:error, :unknown_buffer} = Device.dma_read(dev, ba, 0, 4)
    assert {:error, :unknown_buffer} = Device.free_dma(dev, ba)
    {:ok, %DmaBuffer{iova: c}} = Device.alloc_dma(dev, 16)
    assert c > b
  end

  test "IRQ delivery and unsubscribe" do
    dev = open()
    assert :ok = Device.subscribe_irq(dev, 3)
    id = dev.id
    Mock.trigger_irq(dev, 3)
    assert_receive {:ex_pcie_irq, ^id, 3}
    Mock.trigger_irq(dev, 4)
    refute_receive {:ex_pcie_irq, _, 4}, 20

    other = spawn_link(fn -> receive do: (m -> send(:erlang.group_leader(), m)) end)
    assert :ok = Device.subscribe_irq(dev, 3, other)
    assert :ok = Device.unsubscribe_irq(dev, 3)
    Mock.trigger_irq(dev, 3)
    refute_receive {:ex_pcie_irq, _, 3}, 20
  end

  test "concurrent users" do
    dev = open(bars: %{0 => 4096})

    1..8
    |> Task.async_stream(fn i ->
      for k <- 0..99, do: :ok = Device.write32(dev, 0, i * 400 + k * 4, k)
      for k <- 0..99, do: {:ok, ^k} = Device.read32(dev, 0, i * 400 + k * 4)
    end)
    |> Stream.run()
  end
end
