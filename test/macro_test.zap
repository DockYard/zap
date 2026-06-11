pub struct MacroTest {
  use Zest.Case

  pub macro make_generated_function(label :: Expr, body :: Expr) -> Expr {
    quote {
      pub fn generated_from_trailing_block() -> String {
        unquote(label) <> ": " <> unquote(body)
      }
    }
  }

  pub macro labeled_block(label :: Expr, body :: Expr) -> Expr {
    quote {
      unquote(label) <> ": " <> unquote(body)
    }
  }

  pub macro classify_macro_arg(1 :: Integer) -> Expr {
    quote { "one" }
  }

  pub macro classify_macro_arg(:ok :: Atom) -> Expr {
    quote { "ok" }
  }

  pub macro classify_macro_arg(_value :: Expr) -> Expr {
    quote { "other" }
  }

  pub macro classify_type(i32) -> Expr {
    quote { "i32" }
  }

  pub macro classify_type(f32) -> Expr {
    quote { "f32" }
  }

  pub macro classify_type(_lane_type :: Type) -> Expr {
    quote { "other" }
  }

  pub macro compile_time_member?(value :: Integer) -> Expr {
    if value in [2, 3, 4, 8, 16] {
      quote { true }
    } else {
      quote { false }
    }
  }

  pub macro classify_guarded_lane(lanes :: Integer) -> Expr if lanes not in [2, 3, 4, 8, 16] {
    quote { "unsupported" }
  }

  pub macro classify_guarded_lane(_lanes :: Integer) -> Expr {
    quote { "supported" }
  }

  make_generated_function("generated") {
    "ran"
  }

  describe("macros") {
    test("if true returns yes") {
      assert(if_true() == "yes")
    }

    test("if false returns no") {
      assert(if_false() == "no")
    }
  }

  describe("trailing block syntax") {
    test("macro generates function from trailing block") {
      assert(generated_from_trailing_block() == "generated: ran")
    }

    test("macro receives trailing block as AST") {
      result = labeled_block("check math") {
        "passed"
      }

      assert(result == "check math: passed")
    }

    test("trailing block is the last function argument") {
      result = with_block("test") {
        "hello"
      }

      assert(result == "test: hello")
    }

    test("nested trailing blocks compose inside-out") {
      result = outer_block("describe") {
        inner_block("test") {
          "pass"
        }
      }

      assert(result == "[describe (test pass)]")
    }
  }

  describe("macro clause dispatch") {
    test("dispatches on literal macro argument patterns") {
      assert(classify_macro_arg(1) == "one")
      assert(classify_macro_arg(:ok) == "ok")
      assert(classify_macro_arg(2) == "other")
    }

    test("dispatches on concrete Type macro argument patterns") {
      assert(classify_type(i32) == "i32")
      assert(classify_type(f32) == "f32")
      assert(classify_type(String) == "other")
    }

    test("folds list membership inside macro bodies") {
      assert(compile_time_member?(4) == true)
      assert(compile_time_member?(5) == false)
    }

    test("dispatches macro clauses with not in guards") {
      assert(classify_guarded_lane(4) == "supported")
      assert(classify_guarded_lane(5) == "unsupported")
    }
  }

  fn if_true() -> String {
    case true {
      true -> "yes"
      false -> "no"
    }
  }

  fn if_false() -> String {
    case false {
      true -> "yes"
      false -> "no"
    }
  }

  fn with_block(label :: String, body :: String) -> String {
    label <> ": " <> body
  }

  fn outer_block(label :: String, body :: String) -> String {
    "[" <> label <> " " <> body <> "]"
  }

  fn inner_block(label :: String, body :: String) -> String {
    "(" <> label <> " " <> body <> ")"
  }
}
