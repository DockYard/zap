defmodule Limits do
  @effective_timeout :: i64 = 5000
  def effective_timeout() :: i64 do
    @effective_timeout
  end

  @max_payload :: i64 = 65536
  def max_payload() :: i64 do
    @max_payload
  end
end
