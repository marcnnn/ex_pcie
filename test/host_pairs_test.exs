defmodule ExPcie.HostPairsTest do
  use ExUnit.Case, async: true

  alias ExPcie.{Device, Host, Regs}
  alias ExPcie.Host.Ring
  alias ExPcie.Model.Core
  alias ExPcie.Sim.Card

  setup do
    {:ok, dev, card} =
      Card.open(pairs: 2, seed: 2, rq_ready: 0.8, rc_valid: 0.8, irq_latency: {1, 4})

    for v <- 0..3, do: :ok = Device.subscribe_irq(dev, v)
    %{dev: dev, card: card}
  end

  test "the host finds the pairs and names the vectors", %{dev: dev} do
    assert :ok = Host.check_id(dev)
    assert Host.pairs(dev) == 2
    assert %{vectors: 4} = Host.fields(dev, :caps)
    assert Host.vector(:h2c, 1) == 2 and Host.vector(:c2h, 1) == 3
    assert Host.offset(:ctrl1) == 0x210
    :ok = Host.write_fields(dev, :ctrl1, h2c_run: 1)
    assert %{h2c_run: 1, c2h_run: 0} = Host.fields(dev, :ctrl1)
    assert %{h2c_run: 0} = Host.fields(dev, :ctrl)
    :ok = Host.write_fields(dev, :ctrl1, [])
  end

  test "one pair: the pairs register is a hole and the count is 1" do
    {:ok, dev, _card} = Card.open()
    assert Host.pairs(dev) == 1
  end

  test "simple rings of pair 1 in loopback, interrupts on vectors 2 and 3", %{
    dev: dev,
    card: card
  } do
    :rand.seed(:exsss, {1, 2, 3})
    {:ok, tx} = Device.alloc_dma(dev, 4096)
    {:ok, rx} = Device.alloc_dma(dev, 4096)
    data = :rand.bytes(4096)
    :ok = Device.dma_write(dev, tx, 0, data)

    :ok = Host.start_c2h(dev, rx, period: 512, pair: 1)
    :ok = Host.start_h2c(dev, tx, period: 512, pair: 1)

    for _ <- 1..30, do: Card.advance(card, 100)
    assert :ok = Host.wait_irq(dev, 2, 0)
    assert :ok = Host.wait_irq(dev, 3, 0)
    assert :timeout = Host.wait_irq(dev, 0, 0)
    assert :timeout = Host.wait_irq(dev, 1, 0)

    assert Host.status(dev, 1) == %{h2c_period: true, c2h_period: true, h2c_error: false}
    assert Host.status(dev) == %{h2c_period: false, c2h_period: false, h2c_error: false}
    assert rem(Host.ptr(dev, :c2h, 1), 32) == 0
    assert Host.ptr(dev, :c2h) == 0
    {:ok, ring} = Device.dma_read(dev, rx, 0, 4096)
    assert ring == data

    Host.stop(dev, :h2c, 1)
    Host.stop(dev, :c2h, 1)
    Card.advance(card, 50)
    Host.clear_status(dev, 7, 1)
    assert Host.status(dev, 1) == %{h2c_period: false, c2h_period: false, h2c_error: false}
    assert Host.ptr(dev, :c2h, 1) == 0
    assert Host.h2c_errors(dev, 1) == 0
    assert Core.errors(Card.core(card)) == []
  end

  test "descriptor rings of both pairs at once", %{dev: dev, card: card} do
    :rand.seed(:exsss, {7, 8, 9})
    {:ok, tx0} = Device.alloc_dma(dev, 4096)
    {:ok, tx1} = Device.alloc_dma(dev, 4096)
    {:ok, rx0} = Device.alloc_dma(dev, 4096)
    {:ok, rx1} = Device.alloc_dma(dev, 4096)
    d0 = :rand.bytes(2048)
    d1 = :rand.bytes(2048)
    :ok = Device.dma_write(dev, tx0, 0, d0)
    :ok = Device.dma_write(dev, tx1, 0, d1)

    open = fn ch, opts ->
      elem(Ring.open(dev, Regs.channel(elem(ch, 0), elem(ch, 1)), opts), 1)
    end

    h0 = open.({:h2c, 0}, entries: 8, irq: true)
    c0 = open.({:c2h, 0}, entries: 8, irq: true)
    h1 = open.({:h2c, 1}, entries: 8, irq: true)
    c1 = open.({:c2h, 1}, entries: 8, irq: true)
    assert h1.ch == :h2c1

    post = fn r, buf, off, len ->
      {:ok, r} = Ring.post(r, buf, off, len, [:irq])
      r
    end

    h0 = post.(h0, tx0, 0, 2048)
    h1 = Enum.reduce(0..3, h1, fn i, r -> post.(r, tx1, i * 512, 512) end)
    c0 = post.(c0, rx0, 0, 2048)
    c1 = Enum.reduce(0..3, c1, fn i, r -> post.(r, rx1, i * 512, 512) end)

    for r <- [c0, c1, h0, h1], do: :ok = Ring.start(r)
    for r <- [c0, c1, h0, h1], do: :ok = Ring.doorbell(r)

    # loopback wires the streams inside each pair: the C2H of a pair gets its own H2C data
    for _ <- 1..60, do: Card.advance(card, 100)
    for v <- 0..3, do: assert(:ok = Host.wait_irq(dev, v, 0))

    assert {:ok, ^d0} = Device.dma_read(dev, rx0, 0, 2048)
    assert {:ok, ^d1} = Device.dma_read(dev, rx1, 0, 2048)
    assert Ring.head(h1) == %{tail: 4, count: 4}
    assert Ring.head(h0) == %{tail: 1, count: 1}
    assert %{completed: 4} = Ring.status(h1)
    assert %{completed: 1} = Ring.status(h0)
    {:ok, _h1, done} = Ring.reap(h1)
    assert length(done) == 4

    # stopping pair 1 leaves pair 0 alone
    h1 = Ring.stop(h1)
    assert h1.head == 0
    Card.advance(card, 50)
    assert %{tail: 0, completed: 0} = Ring.status(h1)
    assert %{completed: 1} = Ring.status(h0)
    assert Core.errors(Card.core(card)) == []
  end
end
