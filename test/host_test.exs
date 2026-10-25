defmodule ExPcie.HostTest do
  use ExUnit.Case, async: true

  alias ExPcie.{Device, DRing, Host}
  alias ExPcie.Host.Ring
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

    test "descriptor rings: loopback with write-back and interrupts", %{dev: dev, card: card} do
      :rand.seed(:exsss, {4, 5, 6})
      {:ok, tx} = Device.alloc_dma(dev, 8192)
      {:ok, rx} = Device.alloc_dma(dev, 8192)
      data = :rand.bytes(4096)
      :ok = Device.dma_write(dev, tx, 0, data)

      assert %{desc: 1} = Host.fields(dev, :caps)
      {:ok, h2c} = Ring.open(dev, :h2c, entries: 8, irq: true)
      {:ok, c2h} = Ring.open(dev, :c2h, entries: 8, wb: :desc, irq: true)

      # four H2C descriptors of 1 KiB, the last one with an interrupt; C2H 2 KiB buffers
      h2c =
        Enum.reduce(0..3, h2c, fn i, r ->
          {:ok, r} = Ring.post(r, tx, i * 1024, 1024, if(i == 3, do: [:irq], else: []), i)
          r
        end)

      c2h =
        Enum.reduce(0..1, c2h, fn i, r ->
          {:ok, r} = Ring.post(r, rx, i * 2048, 2048, [:irq], 10 + i)
          r
        end)

      :ok = Ring.start(c2h)
      :ok = Ring.start(h2c)
      :ok = Ring.doorbell(c2h)
      :ok = Ring.doorbell(h2c)

      for _ <- 1..60, do: Card.advance(card, 100)
      assert :ok = Host.wait_irq(dev, 0, 0)
      assert :ok = Host.wait_irq(dev, 1, 0)

      assert Ring.head(h2c) == %{tail: 4, count: 4}
      assert %{completed: 4, halted: false} = Ring.status(h2c)
      {:ok, h2c, done} = Ring.reap(h2c)
      assert Enum.map(done, & &1.bytes) == [1024, 1024, 1024, 1024]
      assert Ring.space(h2c) == 7

      {:ok, c2h, done} = Ring.reap(c2h)
      assert Enum.map(done, &{&1.bytes, &1.cookie}) == [{2048, 10}, {2048, 11}]
      assert {:ok, ^data} = Device.dma_read(dev, rx, 0, 4096)
      assert Ring.space(c2h) == 7

      # the ring restarts at index 0 after a stop
      h2c = Ring.stop(h2c)
      assert h2c.head == 0
      Card.advance(card, 50)
      assert %{tail: 0, completed: 0} = Ring.status(h2c)
      assert {:error, :unaligned} = Ring.post(h2c, tx, 16, 64)
      assert Core.errors(Card.core(card)) == []
      assert DRing.size() == 32
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
