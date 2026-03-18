# Shared type definitions — no modules, just data shapes.

defstruct Shape do
  color :: String = "black"
end

defstruct Circle extends Shape do
  radius :: f64
end

defstruct Rectangle extends Shape do
  width :: f64
  height :: f64
end

defenum Color do
  Red
  Green
  Blue
end
