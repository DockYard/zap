pub module Test.TestRunner {
  use Zest

  pub fn main(_args :: [String]) -> String {
    IO.puts("Running Zap tests...")

    IO.puts(Test.HelloWorldTest.run())
    IO.puts(Test.PatternMatchingTest.run())
    IO.puts(Test.PipesTest.run())
    IO.puts(Test.CaseExpressionTest.run())
    IO.puts(Test.StringTest.run())
    IO.puts(Test.ArithmeticTest.run())
    IO.puts(Test.BooleanTest.run())
    IO.puts(Test.AtomTest.run())
    IO.puts(Test.FunctionTest.run())
    IO.puts(Test.MacroTest.run())
    IO.puts(Test.RecursionTest.run())
    IO.puts(Test.GuardTest.run())
    IO.puts(Test.MultiModuleTest.run())
    IO.puts(Test.ImportTest.run())
    IO.puts(Test.UnionTest.run())
    IO.puts(Test.CondTest.run())
    IO.puts(Test.MultiArityTest.run())
    IO.puts(Test.IfElseTest.run())
    IO.puts(Test.TupleTest.run())
    IO.puts(Test.DefaultParamsTest.run())
    IO.puts(Test.CatchBasinTest.run())

    IO.puts("All tests passed!")
  }
}
