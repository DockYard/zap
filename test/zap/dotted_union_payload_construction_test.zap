@doc = """
  Regression: a PAYLOAD-carrying variant of a NAMESPACED (dotted) union —
  `Telemetry.Reading.Sample("bytes")`, the exact shape of the stdlib
  `Socket.Recv.Chunk(bytes)` — must lower to a DIRECT `union_init` carrying the
  argument, exactly like the 2-part form `Result.Ok(x)` always has.

  The HIR call lowering recognised a variant-constructor call only when the
  callee had EXACTLY two parts (`parts.len == 2`), so a 3-part dotted call fell
  through to the generic call path: the bare constructor was materialised as a
  `union_init` with a NIL payload and then invoked as a closure. Sema rejected
  the nil payload against the variant's real payload type ("expected type
  '[]const u8', found '@TypeOf(null)'") — every payload construction on every
  namespaced stdlib union (`Socket.Recv`, `Socket.DatagramRecv`,
  `Framer.Error`, `Stream.UnfoldStep`) failed to compile. The owner type is now
  resolved through `resolveStructRefVariantOwnerTypeId`, the same helper the
  nullary (`Telemetry.Reading.Offline`) arm uses, so the two shapes cannot
  drift again.

  The cases also pin the surrounding namespaced-type plumbing this shape
  depends on: the dotted union as a RETURN type and PARAMETER type (the
  standalone `Telemetry_Reading` module, Step 3.6), a dotted FIELD-ONLY struct
  as a variant payload and parameter (the standalone `Telemetry_Fault` module,
  Step 3.5), and 3-part dotted PATTERNS with payload extraction in `case`.

  Conformance: this file declares EXACTLY ONE method-bearing struct
  (`Zap.DottedUnionPayloadConstructionTest`) so `validateOneStructPerFile`
  accepts it into the manifest full-suite. `Telemetry` is a FIELD-ONLY data
  struct that exists solely to anchor the dotted `Telemetry.*` leaves;
  `Telemetry.Fault` is a field-only PAYLOAD struct; the helper functions that
  construct, return, and match the union live INSIDE the single test struct,
  mirroring `test/zap/dotted_union_enum_param_test.zap`.
  """

pub struct Telemetry {
  station :: String
}

pub struct Telemetry.Fault {
  code :: i64
}

pub union Telemetry.Reading {
  Sample :: String
  Gap :: i64
  Offline
  Fault :: Telemetry.Fault
}

pub struct Zap.DottedUnionPayloadConstructionTest {
  use Zest.Case

  describe("payload-carrying variants of a namespaced (dotted) union") {
    test("a String-payload variant constructs directly and round-trips through case") {
      reading = Telemetry.Reading.Sample("22 celsius")
      assert(describe_reading(reading) == "sample:22 celsius")
    }

    test("an i64-payload variant constructs through a returning helper") {
      assert(describe_reading(gap_of(41)) == "gap:41")
    }

    test("a payload-FREE variant of the same union still constructs bare") {
      assert(describe_reading(Telemetry.Reading.Offline) == "offline")
    }

    test("a dotted-STRUCT payload threads construction, extraction, and a struct parameter") {
      reading = Telemetry.Reading.Fault(%Telemetry.Fault{code: 7})
      assert(describe_reading(reading) == "fault:7")
    }

    test("the dotted union round-trips as parameter AND return type unchanged") {
      forwarded = forward_reading(Telemetry.Reading.Sample("intact"))
      assert(describe_reading(forwarded) == "sample:intact")
    }
  }

  fn describe_reading(reading :: Telemetry.Reading) -> String {
    case reading {
      Telemetry.Reading.Sample(bytes) -> "sample:" <> bytes
      Telemetry.Reading.Gap(missed_count) -> "gap:" <> Integer.to_string(missed_count)
      Telemetry.Reading.Offline -> "offline"
      Telemetry.Reading.Fault(fault) -> "fault:" <> Integer.to_string(fault_code(fault))
    }
  }

  fn gap_of(missed_count :: i64) -> Telemetry.Reading {
    Telemetry.Reading.Gap(missed_count)
  }

  fn forward_reading(reading :: Telemetry.Reading) -> Telemetry.Reading {
    reading
  }

  fn fault_code(fault :: Telemetry.Fault) -> i64 {
    fault.code
  }
}
