pub module Snake {
  @moduledoc = """
    A terminal snake game demonstrating Zap language features:
    pattern matching, guards, pipes, char literals, and closures.

    Move with w/a/s/d or arrow keys.
    Collect * to grow. Hit a wall or yourself and it's game over.
    Press q to quit.

    Run with: cd examples/snake && zap run snake
    """

  # -- ANSI color helpers ------------------------------------------------------

  fn green(text :: String) -> String { "\x1b[32m" <> text <> "\x1b[0m" }
  fn red(text :: String) -> String { "\x1b[91m" <> text <> "\x1b[0m" }
  fn yellow(text :: String) -> String { "\x1b[33m" <> text <> "\x1b[0m" }
  fn cyan(text :: String) -> String { "\x1b[96m" <> text <> "\x1b[0m" }
  fn magenta(text :: String) -> String { "\x1b[95m" <> text <> "\x1b[0m" }
  fn bold_green(text :: String) -> String { "\x1b[1;92m" <> text <> "\x1b[0m" }
  fn dim(text :: String) -> String { "\x1b[2m" <> text <> "\x1b[0m" }
  fn bold(text :: String) -> String { "\x1b[1m" <> text <> "\x1b[0m" }

  # -- Entry -------------------------------------------------------------------

  pub fn main(_args :: [String]) -> String {
    "\x1b[2J\x1b[H" |> IO.print_str()
    IO.puts(green("  ___ _  _   _   _  _____"))
    IO.puts(green(" / __| \\| | /_\\ | |/ / __|"))
    IO.puts(green(" \\__ \\ .` |/ _ \\|   <| _|"))
    IO.puts(green(" |___/_|\\_/_/ \\_\\_|\\_\\___|"))
    IO.puts("")
    IO.puts("  wasd / arrows = move")
    IO.puts("  q = quit")
    IO.puts("")
    IO.puts("  Collect the " <> yellow("*") <> " to grow!")
    IO.puts("  Press any key to start...")
    IO.mode(IO.Mode.Raw, fn() -> String {
      IO.get_char()
      "\x1b[2J\x1b[H" |> IO.print_str()
      run([10], [5], 3, 2, 0, "d")
      ""
    })
  }

  # -- Game loop ---------------------------------------------------------------

  fn run(body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 {
    "\x1b[H" |> IO.print_str()
    draw(body_xs, body_ys, food_x, food_y, score)
    sleep(150)
    next_dir = read_key() |> update_direction(direction)
    tick(body_xs, body_ys, food_x, food_y, score, next_dir)
  }

  # -- Input -------------------------------------------------------------------

  fn read_key() -> String {
    first = IO.try_get_char()
    if first == "\x1b" {
      read_escape_seq()
    } else {
      first
    }
  }

  fn read_escape_seq() -> String {
    bracket = IO.try_get_char()
    if bracket == "[" {
      IO.try_get_char() |> arrow_to_wasd()
    } else {
      ""
    }
  }

  fn arrow_to_wasd("A") -> String { "w" }
  fn arrow_to_wasd("B") -> String { "s" }
  fn arrow_to_wasd("C") -> String { "d" }
  fn arrow_to_wasd("D") -> String { "a" }
  fn arrow_to_wasd(_ :: String) -> String { "" }

  fn update_direction("", direction :: String) -> String { direction }
  fn update_direction("q", _direction :: String) -> String { "q" }
  fn update_direction(key :: String, direction :: String) -> String {
    is_valid = key == "w" or key == "a" or key == "s" or key == "d"
    if is_valid { key } else { direction }
  }

  # -- Tick / movement ---------------------------------------------------------

  fn tick(_body_xs :: [i64], _body_ys :: [i64], _fx :: i64, _fy :: i64, score :: i64, "q") -> i64 {
    game_over(score)
  }

  fn tick(body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 {
    next_x = body_xs |> List.head() |> move_x(direction)
    next_y = body_ys |> List.head() |> move_y(direction)
    status = check_position(next_x, next_y, body_xs, body_ys)
    handle_status(status, body_xs, body_ys, next_x, next_y, food_x, food_y, score, direction)
  }

  fn handle_status(:ok :: Atom, body_xs :: [i64], body_ys :: [i64], next_x :: i64, next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 {
    advance(body_xs, body_ys, next_x, next_y, food_x, food_y, score, direction)
  }

  fn handle_status(:wall :: Atom, body_xs :: [i64], body_ys :: [i64], _next_x :: i64, _next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, _direction :: String) -> i64 {
    "\x1b[2J\x1b[H" |> IO.print_str()
    draw_death(body_xs, body_ys, food_x, food_y, score)
    IO.puts(red("  CRASH! You hit a wall!"))
    game_over(score)
  }

  fn handle_status(:self_collision :: Atom, body_xs :: [i64], body_ys :: [i64], _next_x :: i64, _next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, _direction :: String) -> i64 {
    "\x1b[2J\x1b[H" |> IO.print_str()
    draw_death(body_xs, body_ys, food_x, food_y, score)
    IO.puts(red("  OUCH! You bit yourself!"))
    game_over(score)
  }

  fn check_position(x :: i64, y :: i64, _body_xs :: [i64], _body_ys :: [i64]) -> Atom if x < 0 or x > 19 or y < 0 or y > 9 {
    :wall
  }

  fn check_position(x :: i64, y :: i64, body_xs :: [i64], body_ys :: [i64]) -> Atom {
    hit_self = body_hit(body_xs, body_ys, x, y, 0)
    if hit_self { :self_collision } else { :ok }
  }

  fn advance(body_xs :: [i64], body_ys :: [i64], next_x :: i64, next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 if next_x == food_x and next_y == food_y {
    grow(body_xs, body_ys, next_x, next_y, score, direction)
  }

  fn advance(body_xs :: [i64], body_ys :: [i64], next_x :: i64, next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 {
    slither(body_xs, body_ys, next_x, next_y, food_x, food_y, score, direction)
  }

  fn grow(body_xs :: [i64], body_ys :: [i64], next_x :: i64, next_y :: i64, score :: i64, direction :: String) -> i64 {
    new_score = score + 1
    new_xs = body_xs |> List.prepend(next_x)
    new_ys = body_ys |> List.prepend(next_y)
    new_food_x = new_score |> next_food_x()
    new_food_y = new_score |> next_food_y()
    run(new_xs, new_ys, new_food_x, new_food_y, new_score, direction)
  }

  fn slither(body_xs :: [i64], body_ys :: [i64], next_x :: i64, next_y :: i64, food_x :: i64, food_y :: i64, score :: i64, direction :: String) -> i64 {
    body_len = body_xs |> List.length()
    new_xs = body_xs |> List.prepend(next_x) |> List.take(body_len)
    new_ys = body_ys |> List.prepend(next_y) |> List.take(body_len)
    run(new_xs, new_ys, food_x, food_y, score, direction)
  }

  fn move_x(x :: i64, "a") -> i64 { x - 1 }
  fn move_x(x :: i64, "d") -> i64 { x + 1 }
  fn move_x(x :: i64, _ :: String) -> i64 { x }

  fn move_y(y :: i64, "w") -> i64 { y - 1 }
  fn move_y(y :: i64, "s") -> i64 { y + 1 }
  fn move_y(y :: i64, _ :: String) -> i64 { y }

  # -- Collision ---------------------------------------------------------------

  fn body_hit(xs :: [i64], ys :: [i64], x :: i64, y :: i64, index :: i64) -> Bool {
    done = index >= List.length(xs)
    if done { false } else {
      at_x = xs |> List.at(index)
      at_y = ys |> List.at(index)
      matched = at_x == x and at_y == y
      if matched { true } else { body_hit(xs, ys, x, y, index + 1) }
    }
  }

  # -- Food placement ----------------------------------------------------------

  fn next_food_x(score :: i64) -> i64 {
    Integer.remainder(score * 7 + 3, 18) + 1
  }

  fn next_food_y(score :: i64) -> i64 {
    Integer.remainder(score * 5 + 1, 8) + 1
  }

  # -- Rendering ---------------------------------------------------------------

  fn game_over(score :: i64) -> i64 {
    IO.puts("")
    IO.puts(bold("  Final score: " <> Integer.to_string(score)))
    IO.puts("")
    score
  }

  fn draw(body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64, score :: i64) -> String {
    border = String.repeat("-", 20)
    IO.puts(dim("  +" <> border <> "+"))
    draw_rows(0, body_xs, body_ys, food_x, food_y)
    IO.puts(dim("  +" <> border <> "+"))
    IO.puts(cyan("  Score: " <> Integer.to_string(score)))
    IO.puts(dim("  wasd/arrows = move  q = quit"))
    ""
  }

  fn draw_rows(row :: i64, _body_xs :: [i64], _body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String if row > 9 { "" }
  fn draw_rows(row :: i64, body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64) -> String {
    IO.puts(dim("  |") <> build_row(0, row, body_xs, body_ys, food_x, food_y) <> dim("|"))
    draw_rows(row + 1, body_xs, body_ys, food_x, food_y)
  }

  fn build_row(col :: i64, _row :: i64, _body_xs :: [i64], _body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String if col > 19 { "" }
  fn build_row(col :: i64, row :: i64, body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64) -> String {
    cell = cell_char(col, row, body_xs, body_ys, food_x, food_y)
    cell <> build_row(col + 1, row, body_xs, body_ys, food_x, food_y)
  }

  fn cell_char(col :: i64, row :: i64, [col | _body_xs] :: [i64], [row | _body_ys] :: [i64], _food_x :: i64, _food_y :: i64) -> String { bold_green("@") }
  fn cell_char(col :: i64, row :: i64, _body_xs :: [i64], _body_ys :: [i64], col :: i64, row :: i64) -> String { magenta("*") }
  fn cell_char(col :: i64, row :: i64, body_xs :: [i64], body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String {
    is_body = body_hit(body_xs, body_ys, col, row, 0)
    if is_body { green("o") } else { dim(".") }
  }

  # -- Death screen ------------------------------------------------------------

  fn draw_death(body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64, score :: i64) -> String {
    border = String.repeat("-", 20)
    IO.puts(dim("  +" <> border <> "+"))
    draw_death_rows(0, body_xs, body_ys, food_x, food_y)
    IO.puts(dim("  +" <> border <> "+"))
    IO.puts(cyan("  Score: " <> Integer.to_string(score)))
    ""
  }

  fn draw_death_rows(row :: i64, _body_xs :: [i64], _body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String if row > 9 { "" }
  fn draw_death_rows(row :: i64, body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64) -> String {
    IO.puts(dim("  |") <> build_death_row(0, row, body_xs, body_ys, food_x, food_y) <> dim("|"))
    draw_death_rows(row + 1, body_xs, body_ys, food_x, food_y)
  }

  fn build_death_row(col :: i64, _row :: i64, _body_xs :: [i64], _body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String if col > 19 { "" }
  fn build_death_row(col :: i64, row :: i64, body_xs :: [i64], body_ys :: [i64], food_x :: i64, food_y :: i64) -> String {
    cell = dead_cell_char(col, row, body_xs, body_ys, food_x, food_y)
    cell <> build_death_row(col + 1, row, body_xs, body_ys, food_x, food_y)
  }

  fn dead_cell_char(col :: i64, row :: i64, [col | _body_xs] :: [i64], [row | _body_ys] :: [i64], _food_x :: i64, _food_y :: i64) -> String { red("X") }
  fn dead_cell_char(col :: i64, row :: i64, _body_xs :: [i64], _body_ys :: [i64], col :: i64, row :: i64) -> String { magenta("*") }
  fn dead_cell_char(col :: i64, row :: i64, body_xs :: [i64], body_ys :: [i64], _food_x :: i64, _food_y :: i64) -> String {
    is_body = body_hit(body_xs, body_ys, col, row, 0)
    if is_body { red("o") } else { dim(".") }
  }
}
