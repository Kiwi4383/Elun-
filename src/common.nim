import std/[httpclient, os, strutils]

let booksDir* = getHomeDir() / "LFS-BOOKS-DEV"

type FetchFatal* = object of IOError
  ## 4xx o índice inesperado: reintentar no va a ayudar.

proc contentLengthOf(headers: HttpHeaders): string =
  for key, val in headers.pairs:
    if key.toLowerAscii.strip() == "content-length":
      let v = val.strip()
      # Headers duplicados/basura no numéricos se ignoran, no fallan.
      if v != "" and v.allCharsInSet({'0' .. '9'}):
        return v
      return ""
  return ""

proc fetch*(client: HttpClient, url: string): Response =
  ## El script de referencia usa curl --retry 3 y std/httpclient no reintenta,
  ## así que el reintento va acá. Un 4xx no se reintenta: no va a empezar a
  ## contestar 200. Levanta en vez de quit para que el llamador decida
  ## (aviso "no existe" vs abortar todo).
  var problem = "sin respuesta"
  for attempt in 1 .. 3:
    try:
      let response = client.get(url)
      if response.code == Http200:
        # Toda descarga pasa por acá, así que el chequeo contra archivo
        # cortado va acá y cubre los libros, los índices y las páginas.
        let expected = contentLengthOf(response.headers)
        if expected != "" and expected != $response.body.len:
          problem = "llegó cortado (" & $response.body.len & " de " &
            expected & " bytes)"
          if attempt < 3:
            echo "  retry: " & problem
            sleep(1000)
            continue
          break
        return response
      if response.code.int < 500:
        raise newException(FetchFatal, url & " answered HTTP " & $response.code)
      problem = "HTTP " & $response.code
    except FetchFatal:
      raise
    except CatchableError as error:
      problem = error.msg
    if attempt < 3:
      echo "  retry: " & problem
      sleep(1000)
  raise newException(IOError, url & " no se pudo bajar: " & problem)

proc decodeHref*(s: string): string =
  s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    .replace("&quot;", "\"").replace("&#39;", "'")

proc hrefsIn*(index: string): seq[string] =
  ## El índice de descargas es un listado plano de <a href="...">.
  ## Acepta mayúsculas, espacios alrededor del =, comilla simple o doble,
  ## y decodifica entidades para que la URL sea pedible. Solo dentro de tags.
  let low = index.toLowerAscii
  var i = 0
  while true:
    let h = low.find("href", i)
    if h < 0:
      break
    # Debe haber '<' después del último '>' previo: si no, es texto plano.
    let prevOpen = if h > 0: index.rfind('<', 0, h - 1) else: -1
    let prevClose = if h > 0: index.rfind('>', 0, h - 1) else: -1
    if prevOpen < 0 or prevOpen < prevClose:
      i = h + 4
      continue
    var j = h + 4
    while j < index.len and index[j] in {' ', '\t', '\n', '\r', '\f'}:
      inc j
    if j >= index.len or index[j] != '=':
      i = j + 1
      continue
    inc j
    while j < index.len and index[j] in {' ', '\t', '\n', '\r', '\f'}:
      inc j
    if j >= index.len or index[j] notin {'"', '\''}:
      i = j + 1
      continue
    let quote = index[j]
    inc j
    let k = index.find(quote, j)
    if k < 0:
      break
    result.add decodeHref(index[j ..< k])
    i = k + 1
