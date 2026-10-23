defmodule ExPcie.HostTest do
  use ExUnit.Case, async: true

  alias ExPcie.{Device, Host}
  alias ExPcie.Model.Core
  alias ExPcie.Sim.Card

  test "register map comes from the RTL" do
    assert Host.offset(:ctrl) == 0x10
    assert Host.offset(:c2h_ptr) == 0x50
    assert_raise KeyError, fn -> Host.offset(:nope) end
  end

  test "ring helpers wrap" do
    {:ok, dev} = Device.open(:mock)
    {:ok, buf} = Device.alloc_dma(dev, 256)

    :ok =
      Host.write_ring(dev, buf, 128, 96, :binary.copy(<<1>>, 32) <> :binary.copy(<<2>>, 16), 64)

    assert {:ok, bin} = Host.read_ring(dev, buf, 128, 96, 16, 64)
    assert bin == :binary.copy(<<1>>, 32) <> :binary.copy(<<2>>, 16)
    assert {:ok, :binary.copy(<<1>>, 32)} == Host.read_ring(dev, buf, 128, 96, 0, 64)
    assert {:ok, <<>>} = Host.read_ring(dev, buf, 128, 16, 16, 64)
  end

  describe "against the simulated card" do
    setup do
      {:ok, dev, card} = Card.open(seed: 1, rq_ready: 0.8, rc_valid: 0.8, irq_latency: {1, 4})
      for v <- 0..1, do: :ok = Device.subscribe_irq(dev, v)
      %{dev: dev, card: card}
    end

    test "id, argument checks", %{dev: dev} do
      assert :ok = Host.check_id(dev)
      assert %{vectors: 2, stream_bytes: 32} = Host.fields(dev, :caps)
      :ok = Host.write_fields(dev, :ctrl, h2c_run: 1)
      assert %{h2c_run: 1, c2h_run: 0} = Host.fields(dev, :ctrl)
      :ok = Host.write_fields(dev, :ctrl, [])
      {:ok, buf} = Device.alloc_dma(dev, 4096)
      assert {:error, :bad_ring_or_period} = Host.start_c2h(dev, buf, period: 96)
      assert {:error, :unaligned_base} = Host.start_c2h(dev, buf, period: 64, offset: 16)
      assert {:error, :ring_exceeds_buffer} = Host.start_c2h(dev, buf, ring: 8192, period: 512)
    end

    test "loopback through both DMA channels with interrupts", %{dev: dev, card: card} do
      :rand.seed(:exsss, {1, 2, 3})
      {:ok, tx} = Device.alloc_dma(dev, 4096)
      {:ok, rx} = Device.alloc_dma(dev, 4096)
      data = :rand.bytes(4096)
      :ok = Device.dma_write(dev, tx, 0, data)

      :ok = Host.start_c2h(dev, rx, period: 512)
      :ok = Host.start_h2c(dev, tx, period: 512)

      for _ <- 1..30, do: Card.advance(card, 100)
      assert :ok = Host.wait_irq(dev, 0, 0)
      assert :ok = Host.wait_irq(dev, 1, 0)

      assert Host.status(dev) == %{h2c_period: true, c2h_period: true, h2c_error: false}
      ptr = Host.ptr(dev, :c2h)
      assert rem(ptr, 32) == 0
      {:ok, ring} = Device.dma_read(dev, rx, 0, 4096)
      assert ring == data

      Host.clear_status(dev)
      Host.stop(dev, :h2c)
      Host.stop(dev, :c2h)
      Card.advance(card, 50)
      assert Host.ptr(dev, :c2h) == 0
      assert Host.h2c_errors(dev) == 0
      assert Core.errors(Card.core(card)) == []
    end

    test "software interrupt", %{dev: dev, card: card} do
      Host.force_irq(dev, 1)
      Card.advance(card, 40)
      assert :ok = Host.wait_irq(dev, 1, 0)
      assert :timeout = Host.wait_irq(dev, 0, 0)
    end

    test "DMA to an unmapped address is reported by the model", %{dev: dev, card: card} do
      # a buffer that is freed while the card still writes into it
      {:ok, rx} = Device.alloc_dma(dev, 4096)
      :ok = Host.start_c2h(dev, rx, period: 512)
      :ok = Device.free_dma(dev, rx)
      # nothing streams in loopback without H2C, so start it on another buffer
      {:ok, tx} = Device.alloc_dma(dev, 4096)
      :ok = Host.start_h2c(dev, tx, period: 512)
      Card.advance(card, 1500)

      assert Enum.any?(
               Core.errors(Card.core(card)),
               &match?({_, {:dma_write_fault, _, _, :unmapped}}, &1)
             )
    end
  end
end
