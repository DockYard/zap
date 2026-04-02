# Shared type definitions for the multifile example.

pub struct Shape {
  color :: String = "black"
}

pub struct Circle extends Shape {
  radius :: f64
}

pub struct Rectangle extends Shape {
  width :: f64
  height :: f64
}

pub enum Color {
  Red
  Green
  Blue
}

pub module Types {
}
