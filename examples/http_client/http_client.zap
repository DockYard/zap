# A minimal HTTP/1.1 client over Zap's Socket + Tls stack.
#
# Demonstrates:
#   * URL parsing into a typed value (scheme / host / port / path)
#   * plain-TCP requests via `Socket.connect_host` and verified HTTPS via
#     `Tls.connect_host` (real certificate verification — a bad cert is a
#     typed `:tls_cert_invalid` error, never a silent success)
#   * writing a request with `Socket.send_all` and draining the response to
#     EOF with `Socket.fold` (`Connection: close` makes EOF the terminator)
#   * splitting the raw response into status / headers / body
#
# Run with (from examples/http_client/):
#   zap run http_client                             # GET https://example.com/
#   zap run http_client -- http://example.com/      # plain HTTP
#   zap run http_client -- https://any-host/path    # any http(s) URL
#
# Failure modes stay typed and friendly:
#   zap run http_client -- https://self-signed.badssl.com/
#   # => Request failed: connect to self-signed.badssl.com: tls_cert_invalid

@doc = """
  A parsed `http://` / `https://` URL: the four pieces a request needs.

  `scheme` is `:http` or `:https`; `port` defaults to 80/443 when the URL
  does not carry an explicit `:port`; `path` defaults to `/`.
  """

pub struct HttpUrl {
  scheme :: Atom
  host :: String
  port :: i64
  path :: String
}

@doc = """
  A parsed HTTP response: the numeric status code, the raw head (status
  line plus every header, exactly as received), and the body bytes.
  """

pub struct HttpResponse {
  status_code :: i64
  head :: String
  body :: String
}

@doc = """
  The example entry point and the request pipeline: parse the URL, open a
  plain or TLS socket, send one `GET`, drain the response to EOF, and print
  it. Every failure path is a typed `Result` — nothing crashes on a refused
  connection, an unresolvable host, or an untrusted certificate.
  """

pub struct HttpClient {
  @doc = """
    Fetches the URL given as the first CLI argument (defaulting to
    `https://example.com/`) and prints the status line, headers, and body.
    Returns exit code 0 on any completed HTTP exchange and 1 on a
    connection, TLS, or URL failure.
    """

  pub fn main(_args :: [String]) -> u8 {
    url_text = HttpClient.requested_url()
    IO.puts("GET " <> url_text)
    case HttpClient.parse_url(url_text) {
      Result.Error(parse_failure) ->
        {
          IO.puts("URL error: " <> parse_failure)
          1
        }
      Result.Ok(url) ->
        case HttpClient.fetch(url) {
          Result.Error(fetch_failure) ->
            {
              IO.puts("Request failed: " <> fetch_failure)
              1
            }
          Result.Ok(response) ->
            {
              HttpClient.print_response(response)
              0
            }
        }
    }
  }

  @doc = """
    Parses an absolute `http://` or `https://` URL into an `HttpUrl`.

    Splits `host[:port][/path]`: the port defaults to the scheme's well-known
    port (80/443), the path to `/`. Any other scheme — or an empty host — is
    a descriptive `Result.Error`.

    ## Examples

        HttpClient.parse_url("https://example.com/")
        # => Result.Ok(%HttpUrl{scheme: :https, host: "example.com", port: 443, path: "/"})

        HttpClient.parse_url("http://localhost:8080/status")
        # => Result.Ok(%HttpUrl{scheme: :http, host: "localhost", port: 8080, path: "/status"})
    """

  pub fn parse_url(url_text :: String) -> Result(HttpUrl, String) {
    case HttpClient.split_scheme(url_text) {
      Result.Error(scheme_failure) -> Result.Error(scheme_failure)
      Result.Ok(scheme_and_rest) ->
        {
          scheme = scheme_and_rest.0
          rest = scheme_and_rest.1
          slash_index = String.index_of(rest, "/")
          host_and_port = case slash_index >= 0 {
            true -> String.slice(rest, 0, slash_index)
            false -> rest
          }
          path = case slash_index >= 0 {
            true -> String.slice(rest, slash_index, String.length(rest))
            false -> "/"
          }
          case String.length(host_and_port) == 0 {
            true -> Result.Error("missing host in \"" <> url_text <> "\"")
            false ->
              {
                colon_index = String.index_of(host_and_port, ":")
                host = case colon_index >= 0 {
                  true -> String.slice(host_and_port, 0, colon_index)
                  false -> host_and_port
                }
                port = case colon_index >= 0 {
                  true ->
                    {
                      port_text = String.slice(host_and_port, colon_index + 1, String.length(host_and_port))
                      HttpClient.port_or_default(String.to_integer(port_text), HttpClient.default_port(scheme))
                    }
                  false -> HttpClient.default_port(scheme)
                }
                Result.Ok(%HttpUrl{scheme: scheme, host: host, port: port, path: path})
              }
          }
        }
    }
  }

  @doc = """
    Performs one `GET` request for the parsed URL: connect (TLS-verified for
    `:https`), send the request, drain the response to EOF, close, and parse.
    Failures carry a human-readable reason built from the typed
    `SocketError` (`:econnrefused`, `:nxdomain`, `:tls_cert_invalid`, ...).
    """

  pub fn fetch(url :: HttpUrl) -> Result(HttpResponse, String) {
    case HttpClient.open_connection(url) {
      Result.Error(connect_error) ->
        Result.Error("connect to " <> url.host <> ": " <> Atom.to_string(connect_error.reason))
      Result.Ok(socket) ->
        case Socket.send_all(socket, HttpClient.request_text(url), 15000) {
          Result.Error(send_error) ->
            {
              _closed = Socket.close(socket)
              Result.Error("send: " <> Atom.to_string(send_error.reason))
            }
          Result.Ok(_bytes_sent) ->
            {
              drained = Socket.fold(socket, "", 15000, fn(accumulated :: String, chunk :: String) -> {Atom, String} { {:cont, accumulated <> chunk} })
              _closed = Socket.close(socket)
              case drained {
                Result.Error(recv_error) -> Result.Error("recv: " <> Atom.to_string(recv_error.reason))
                Result.Ok(raw_response) -> Result.Ok(HttpClient.parse_response(raw_response))
              }
            }
        }
    }
  }

  @doc = """
    Splits a raw HTTP/1.1 response into an `HttpResponse`: the head ends at
    the first blank line (`CRLF CRLF`); the status code is the second token
    of the status line (0 when the response is not parseable HTTP). A
    `Transfer-Encoding: chunked` body is decoded into its plain bytes
    (each chunk's hex-size framing stripped); any other body passes
    through untouched.
    """

  pub fn parse_response(raw_response :: String) -> HttpResponse {
    separator_index = String.index_of(raw_response, "\r\n\r\n")
    head = case separator_index >= 0 {
      true -> String.slice(raw_response, 0, separator_index)
      false -> raw_response
    }
    raw_body = case separator_index >= 0 {
      true -> String.slice(raw_response, separator_index + 4, String.length(raw_response))
      false -> ""
    }
    %HttpResponse{status_code: HttpClient.status_code_of(head), head: head, body: HttpClient.decoded_body(head, raw_body)}
  }

  # ---- helpers ----

  # The URL to fetch: the first CLI argument, or the default demo URL.
  fn requested_url() -> String {
    case System.arg_count() >= 1 {
      true -> System.arg_at(0)
      false -> "https://example.com/"
    }
  }

  # Strip and classify the scheme prefix; everything after `://` is returned
  # for host/port/path splitting.
  fn split_scheme(url_text :: String) -> Result({Atom, String}, String) {
    case String.starts_with?(url_text, "https://") {
      true -> Result.Ok({:https, String.slice(url_text, 8, String.length(url_text))})
      false ->
        case String.starts_with?(url_text, "http://") {
          true -> Result.Ok({:http, String.slice(url_text, 7, String.length(url_text))})
          false -> Result.Error("unsupported scheme in \"" <> url_text <> "\" (use http:// or https://)")
        }
    }
  }

  # The scheme's well-known port.
  fn default_port(scheme :: Atom) -> i64 {
    case scheme {
      :https -> 443
      _ -> 80
    }
  }

  # An explicit `:port` that failed to parse as an integer falls back to the
  # scheme default (multi-clause dispatch on the `i64 | nil` parse result).
  fn port_or_default(nil, fallback :: i64) -> i64 {
    fallback
  }

  fn port_or_default(parsed_port :: i64, _fallback :: i64) -> i64 {
    parsed_port
  }

  # `:https` connects through the VERIFIED TLS client (hostname + CA chain
  # checked against the system trust store); `:http` is a plain TCP connect.
  fn open_connection(url :: HttpUrl) -> Result(Socket, SocketError) {
    case url.scheme {
      :https -> Tls.connect_host(url.host, url.port, 15000)
      _ -> Socket.connect_host(url.host, url.port, 15000)
    }
  }

  # One well-formed HTTP/1.1 request. `Connection: close` tells the server to
  # end the connection after the response, so reading to EOF (`Socket.fold`)
  # yields exactly one complete response without chunked-transfer handling.
  fn request_text(url :: HttpUrl) -> String {
    request_line = "GET " <> url.path <> " HTTP/1.1\r\n"
    host_header = "Host: " <> url.host <> "\r\n"
    fixed_headers = "User-Agent: zap-http-client-example/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    request_line <> host_header <> fixed_headers
  }

  # The numeric code from `HTTP/1.1 200 OK` — token two of the status line.
  fn status_code_of(head :: String) -> i64 {
    status_line_end = String.index_of(head, "\r\n")
    status_line = case status_line_end >= 0 {
      true -> String.slice(head, 0, status_line_end)
      false -> head
    }
    tokens = String.split(status_line, " ")
    case List.length(tokens) >= 2 {
      true -> HttpClient.port_or_default(String.to_integer(List.at(tokens, 1)), 0)
      false -> 0
    }
  }

  # A `Transfer-Encoding: chunked` body is decoded; anything else passes
  # through (with `Connection: close`, a non-chunked body is simply every
  # byte after the head).
  fn decoded_body(head :: String, raw_body :: String) -> String {
    case String.contains?(String.downcase(head), "transfer-encoding: chunked") {
      true -> HttpClient.decode_chunks(raw_body, "")
      false -> raw_body
    }
  }

  # One chunk per recursive step: `<hex size>[;ext]\r\n<bytes>\r\n`, ending
  # at the `0`-size terminator chunk. `parse_hex` stops at the first non-hex
  # byte, so a `;extension` suffix on the size line terminates the size
  # naturally, and `String.slice`'s clamping keeps a truncated stream safe.
  fn decode_chunks(remaining :: String, decoded :: String) -> String {
    size_line_end = String.index_of(remaining, "\r\n")
    case size_line_end <= 0 {
      true -> decoded
      false ->
        {
          chunk_size = HttpClient.parse_hex(String.slice(remaining, 0, size_line_end), 0)
          case chunk_size <= 0 {
            true -> decoded
            false ->
              {
                chunk_start = size_line_end + 2
                chunk = String.slice(remaining, chunk_start, chunk_start + chunk_size)
                rest = String.slice(remaining, chunk_start + chunk_size + 2, String.length(remaining))
                HttpClient.decode_chunks(rest, decoded <> chunk)
              }
          }
        }
    }
  }

  # Accumulating hex parser: `"22f"` => 559. Stops (returning what it has) at
  # the first byte that is not a hex digit.
  fn parse_hex(text :: String, accumulated :: i64) -> i64 {
    case String.length(text) == 0 {
      true -> accumulated
      false ->
        {
          digit = String.index_of("0123456789abcdef", String.downcase(String.byte_at(text, 0)))
          case digit < 0 {
            true -> accumulated
            false -> HttpClient.parse_hex(String.slice(text, 1, String.length(text)), accumulated * 16 + digit)
          }
        }
    }
  }

  fn print_response(response :: HttpResponse) -> Nil {
    IO.puts("")
    IO.puts("Status: " <> Integer.to_string(response.status_code))
    IO.puts("")
    IO.puts(response.head)
    IO.puts("")
    IO.puts(response.body)
    nil
  }
}
