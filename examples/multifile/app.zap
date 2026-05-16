@doc = """
  Entry point for the multifile example. Pulls together the data
  declared in `shape.zap`, `circle.zap`, `rectangle.zap`, and
  `color.zap` with the behavior in `geometry.zap`. Run with:

      zap run multifile
  """

pub struct App {
  pub fn main(_args :: [String]) -> u8 {
    circle = %Circle{radius: 2.5, color: "black"}
    rectangle = %Rectangle{width: 3.0, height: 4.0, color: "red"}
    IO.puts("circle area: " <> Float.to_string(Geometry.circle_area(circle)))
    IO.puts("rectangle area: " <> Float.to_string(Geometry.rectangle_area(rectangle)))
    IO.puts("circle color: " <> circle.color)
    IO.puts("rectangle color: " <> rectangle.color)
    IO.puts("describe Red: " <> Geometry.describe_color(Color.Red))
    IO.puts("describe Green: " <> Geometry.describe_color(Color.Green))
    IO.puts("describe Blue: " <> Geometry.describe_color(Color.Blue))
    0
  }
}
