pub module Snake {
  @moduledoc = """
    A terminal snake game.

    Move with w/a/s/d keys (no Enter needed).
    Collect * stars to score. Hit a wall and it's game over.
    Press q to quit.

    Run with: cd examples/snake && zap run snake
    """

  pub fn main(_args :: [String]) -> String {
    IO.puts("\x1b[2J\x1b[H")
    IO.puts("  ___ _  _   _   _  _____")
    IO.puts(" / __| \\| | /_\\ | |/ / __|")
    IO.puts(" \\__ \\ .` |/ _ \\|   <| _|")
    IO.puts(" |___/_|\\_/_/ \\_\\_|\\_\\___|")
    IO.puts("")
    IO.puts("  w = up  s = down")
    IO.puts("  a = left  d = right")
    IO.puts("  q = quit")
    IO.puts("")
    IO.puts("  Collect the * to score!")
    IO.puts("  Press any key to start...")
    IO.mode(Mode.Raw, fn() -> String {
      IO.get_char()
      run(10, 5, 3, 2, 0)
      ""
    })
  }

  fn run(player_x :: i64, player_y :: i64, food_x :: i64, food_y :: i64, score :: i64) -> i64 {
    IO.print_str("\x1b[2J\x1b[H")
    draw(player_x, player_y, food_x, food_y, score)
    key = IO.get_char()
    handle_input(player_x, player_y, food_x, food_y, score, key)
  }

  fn handle_input(px :: i64, py :: i64, fx :: i64, fy :: i64, score :: i64, input :: String) -> i64 {
    is_quit = input == "q"
    if is_quit {
      game_over(score)
    } else {
      nx = move_x(px, input)
      ny = move_y(py, input)
      hit_wall = wall_check(nx, ny)
      if hit_wall {
        IO.print_str("\x1b[2J\x1b[H")
        IO.puts("  CRASH! You hit a wall!")
        IO.puts("")
        game_over(score)
      } else {
        ate = food_check(nx, ny, fx, fy)
        if ate {
          new_score = score + 1
          nfx = next_food_x(new_score)
          nfy = next_food_y(new_score)
          run(nx, ny, nfx, nfy, new_score)
        } else {
          run(nx, ny, fx, fy, score)
        }
      }
    }
  }

  fn game_over(score :: i64) -> i64 {
    IO.puts("  Game Over!")
    IO.puts("  Final score: " <> Integer.to_string(score))
    IO.puts("")
    score
  }

  fn move_x(x :: i64, input :: String) -> i64 {
    is_left = input == "a"
    is_right = input == "d"
    if is_left {
      x - 1
    } else {
      if is_right {
        x + 1
      } else {
        x
      }
    }
  }

  fn move_y(y :: i64, input :: String) -> i64 {
    is_up = input == "w"
    is_down = input == "s"
    if is_up {
      y - 1
    } else {
      if is_down {
        y + 1
      } else {
        y
      }
    }
  }

  fn wall_check(x :: i64, y :: i64) -> Bool {
    too_left = x < 0
    too_right = x > 19
    too_up = y < 0
    too_down = y > 9
    if too_left { true }
    else {
      if too_right { true }
      else {
        if too_up { true }
        else {
          if too_down { true }
          else { false }
        }
      }
    }
  }

  fn food_check(x :: i64, y :: i64, fx :: i64, fy :: i64) -> Bool {
    same_x = x == fx
    if same_x { y == fy } else { false }
  }

  fn next_food_x(score :: i64) -> i64 {
    Integer.remainder(score * 7 + 3, 18) + 1
  }

  fn next_food_y(score :: i64) -> i64 {
    Integer.remainder(score * 5 + 1, 8) + 1
  }

  fn draw(px :: i64, py :: i64, fx :: i64, fy :: i64, score :: i64) -> String {
    IO.puts("  +" <> String.repeat("-", 20) <> "+")
    draw_rows(0, px, py, fx, fy)
    IO.puts("  +" <> String.repeat("-", 20) <> "+")
    IO.puts("  Score: " <> Integer.to_string(score))
    ""
  }

  fn draw_rows(row :: i64, px :: i64, py :: i64, fx :: i64, fy :: i64) -> String {
    done = row > 9
    if done { "" }
    else {
      line = build_row(0, row, px, py, fx, fy)
      IO.puts("  |" <> line <> "|")
      draw_rows(row + 1, px, py, fx, fy)
    }
  }

  fn build_row(col :: i64, row :: i64, px :: i64, py :: i64, fx :: i64, fy :: i64) -> String {
    done = col > 19
    if done { "" }
    else {
      cell = cell_char(col, row, px, py, fx, fy)
      cell <> build_row(col + 1, row, px, py, fx, fy)
    }
  }

  fn cell_char(col :: i64, row :: i64, px :: i64, py :: i64, fx :: i64, fy :: i64) -> String {
    is_player = food_check(col, row, px, py)
    if is_player { "@" }
    else {
      is_food = food_check(col, row, fx, fy)
      if is_food { "*" }
      else { " " }
    }
  }
}
