defmodule ExPcie.TLPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExPcie.{Axis, Desc, TLP}

  test "known header bytes" do
    mrd = %TLP{kind: :mrd, requester_id: 0x0100, tag: 5, address: 0x1000, length_dw: 1}
    assert TLP.encode(mrd) == <<0, 0, 0, 1, 1, 0, 5, 0x0F, 0, 0, 0x10, 0>>

    mwr = %TLP{kind: :mwr, address: 0x1_0000_0010, data: <<1, 2, 3, 4>>, last_be: 0}

    assert TLP.encode(mwr) ==
             <<0x60, 0, 0, 1, 0, 0, 0, 0x0F, 0, 0, 0, 1, 0, 0, 0, 0x10, 1, 2, 3, 4>>

    cpld = %TLP{
      kind: :cpld,
      completer_id: 0x0200,
      byte_count: 4,
      requester_id: 0x0100,
      tag: 5,
      lower_address: 0x10,
      data: <<9, 8, 7, 6>>
    }

    assert TLP.encode(cpld) == <<0x4A, 0, 0, 1, 2, 0, 0, 4, 1, 0, 5, 0x10, 9, 8, 7, 6>>
  end

  test "length 1024 DW is encoded as 0" do
    t = %TLP{kind: :mrd, address: 0, length_dw: 1024}
    <<dw0::32, _::binary>> = TLP.encode(t)
    assert (dw0 &&& 0x3FF) == 0
    assert {:ok, %{length_dw: 1024}} = TLP.decode(TLP.encode(t))
  end

  test "errors" do
    assert {:error, :short} = TLP.decode(<<0, 0>>)

    assert {:error, {:unsupported, 0, 4}} = TLP.decode(<<4, 0, 0, 1, 0::64>>)

    assert_raise ArgumentError, fn ->
      TLP.encode(%TLP{kind: :mwr, address: 2, data: <<0::32>>})
    end

    assert {:error, {:payload_length, 4, 2}} =
             TLP.decode(<<0x40, 0, 0, 2, 0, 0, 0, 0xFF, 0, 0, 0, 0, 1, 2, 3, 4>>)
  end

  test "byte counts and lower address" do
    assert TLP.request_byte_count(1, 0xF, 0) == 4
    assert TLP.request_byte_count(1, 0b0110, 0) == 2
    assert TLP.request_byte_count(1, 0b1000, 0) == 1
    assert TLP.request_byte_count(1, 0b0111, 0) == 3
    assert TLP.request_byte_count(4, 0b1100, 0b0111) == 16 - 2 - 1
    assert TLP.request_byte_count(1, 0, 0) == 1
    assert TLP.lower_address(0x1234, 0b1100) == (0x34 ||| 2)
  end

  test "completion chunks split at RCB boundaries" do
    assert TLP.completion_chunks(0x1000, 256, 64, 256, :none) == [{0x1000, 256}]
    assert TLP.completion_chunks(0x1000, 256, 64, 128, :none) == [{0x1000, 128}, {0x1080, 128}]

    assert TLP.completion_chunks(0x1010, 200, 64, 256) ==
             [{0x1010, 48}, {0x1040, 64}, {0x1080, 64}, {0x10C0, 24}]
  end

  property "TLPs survive encode/decode" do
    check all kind <- member_of([:mrd, :mwr]),
              hi <- member_of([0, 1, 0xABCD]),
              addr <- integer(0..0xFFFF_FFFF),
              n <- integer(1..16),
              tag <- integer(0..255),
              rid <- integer(0..0xFFFF),
              data <- binary(length: n * 4),
              fbe <- integer(0..15),
              lbe <- integer(0..15) do
      t = %TLP{
        kind: kind,
        address: hi <<< 32 ||| (addr &&& ~~~3),
        tag: tag,
        requester_id: rid,
        length_dw: n,
        first_be: fbe,
        last_be: lbe,
        data: if(kind == :mwr, do: data, else: <<>>)
      }

      assert {:ok, ^t} = TLP.decode(TLP.encode(t))
    end
  end

  property "completions survive encode/decode" do
    check all n <- integer(0..16),
              data <- binary(length: n * 4),
              st <- member_of([0, 1, 2, 4]),
              bc <- integer(1..4096),
              la <- integer(0..127) do
      t = %TLP{
        kind: if(n > 0, do: :cpld, else: :cpl),
        completer_id: 7,
        requester_id: 9,
        tag: 3,
        status: st,
        byte_count: bc,
        lower_address: la,
        length_dw: n,
        data: data
      }

      assert {:ok, ^t} = TLP.decode(TLP.encode(t))
    end
  end

  describe "descriptors" do
    property "encode/decode are inverse" do
      check all kind <- member_of([:cq, :cc, :rq, :rc]),
                seed <- integer(1..1_000_000) do
        :rand.seed(:exsss, {seed, 2, 3})

        map =
          for {k, {_, w, type}} <- Desc.fields(kind), into: %{} do
            v =
              case type do
                :bool -> :rand.uniform(2) == 1
                :addr -> :rand.uniform(1 <<< 40) &&& ~~~3
                _ -> :rand.uniform(1 <<< w) - 1
              end

            {k, v}
          end

        int = Desc.encode(kind, map)
        assert int < 1 <<< (32 * Desc.size_dw(kind))

        assert Desc.encode(kind, Desc.decode(kind, int)) == int
        assert Map.delete(Desc.decode(kind, int), :req_type) == Map.delete(map, :req_type)
      end
    end

    test "field positions" do
      assert Desc.encode(:rq, %{address: 0x1_0000_1000, dw_count: 8, req_type: :mem_write, tag: 3}) ==
               (0x1_0000_1000 ||| 8 <<< 64 ||| 1 <<< 75 ||| 3 <<< 96)

      assert Desc.encode(:cc, %{
               lower_address: 0x10,
               byte_count: 4,
               dw_count: 1,
               tag: 5,
               status: 1
             }) ==
               (0x10 ||| 4 <<< 16 ||| 1 <<< 32 ||| 1 <<< 43 ||| 5 <<< 64)

      assert_raise ArgumentError, fn -> Desc.encode(:cq, %{tag: 256}) end
      assert_raise ArgumentError, fn -> Desc.encode(:cq, %{bogus: 1}) end
      assert_raise ArgumentError, fn -> Desc.encode(:cq, %{address: 2}) end
    end
  end

  describe "beats" do
    test "RQ write with 128 B: 5 beats, payload after the 4 DW descriptor" do
      data = :crypto.strong_rand_bytes(128)
      desc = Desc.encode(:rq, %{address: 0x2000, dw_count: 32, req_type: :mem_write})
      beats = Axis.pack(:rq, desc, data, %{first_be: 15, last_be: 15})
      assert length(beats) == 5
      assert Enum.map(beats, & &1.keep) == [255, 255, 255, 255, 0x0F]
      assert Enum.map(beats, & &1.last) == [false, false, false, false, true]
      assert hd(beats).data >>> 128 == :binary.decode_unsigned(binary_part(data, 0, 16), :little)
      assert {:ok, ^desc, ^data, _} = Axis.unpack(:rq, beats)
    end

    test "unpack rejects malformed streams" do
      b = %{data: 0, keep: 0xFF, last: false, user: 0}
      assert {:error, {:tlast, 1}} = Axis.unpack(:cq, [b, %{b | last: false}])

      assert {:error, {:keep, 0, 0b1011_1111}} =
               Axis.unpack(:cq, [%{b | last: true, keep: 0xFF} |> Map.put(:keep, 0b1011_1111)])

      assert {:error, :short} = Axis.unpack(:cq, [%{b | last: true, keep: 3}])
    end

    property "TLP to CQ beats to fields, and RQ/CC/RC round trips" do
      check all n <- integer(1..60),
                addr <- integer(0..0xFFFF_FFFF),
                data <- binary(length: n * 4),
                tag <- integer(0..255),
                dw <- member_of([256, 128]) do
        a = addr &&& ~~~3

        mwr = %TLP{
          kind: :mwr,
          address: a,
          tag: tag,
          requester_id: 0x0100,
          length_dw: n,
          last_be: if(n == 1, do: 0, else: 15),
          data: data
        }

        beats = Axis.cq_beats(mwr, dw: dw)
        assert {:ok, desc, ^data, user} = Axis.unpack(:cq, beats, dw: dw)
        d = Desc.decode(:cq, desc)
        assert %{address: ^a, dw_count: ^n, req_type: :mem_write, tag: ^tag, bar_id: 0} = d
        assert Axis.user_fields(:cq, user).first_be == 15

        rq = Desc.encode(:rq, %{address: a, dw_count: n, req_type: :mem_write, tag: tag})

        rq_beats =
          Axis.pack(:rq, rq, data, %{first_be: 15, last_be: if(n == 1, do: 0, else: 15)}, dw: dw)

        assert {:ok, t, _} = Axis.rq_to_tlp(rq_beats, 0x0100, dw: dw)
        assert t == %{mwr | tc: 0}

        cpl = %TLP{
          kind: :cpld,
          completer_id: 1,
          requester_id: 2,
          tag: tag,
          byte_count: 4 * n,
          length_dw: n,
          data: data
        }

        assert {:ok, ^cpl} =
                 cpl
                 |> Axis.rc_beats(a, true, dw: dw)
                 |> then(&Axis.unpack(:rc, &1, dw: dw))
                 |> then(fn {:ok, desc, p, _} ->
                   d = Desc.decode(:rc, desc)

                   {:ok,
                    %TLP{
                      kind: :cpld,
                      completer_id: d.completer_id,
                      requester_id: d.requester_id,
                      tag: d.tag,
                      byte_count: d.byte_count,
                      length_dw: d.dw_count,
                      data: p
                    }}
                 end)

        cc = Desc.encode(:cc, %{dw_count: n, byte_count: 4 * n, tag: tag, requester_id: 2})

        assert {:ok, %{kind: :cpld, data: ^data, completer_id: 9}} =
                 Axis.cc_to_tlp(Axis.pack(:cc, cc, data, %{}, dw: dw), 9, dw: dw)
      end
    end

    test "RC sideband carries byte enables and end of frame" do
      cpl = %TLP{kind: :cpld, byte_count: 8, length_dw: 2, data: <<0::64>>, tag: 1}
      [b] = Axis.rc_beats(cpl, 0x40, true)
      f = Axis.user_fields(:rc, b.user)
      assert f.byte_en == 0xFF <<< 12
      assert f.is_sof_0 == 1
      assert f.is_eof_0 == (8 ||| 4)
    end
  end
end
