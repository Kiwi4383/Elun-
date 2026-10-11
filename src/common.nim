import std/[httpclient, os, strutils]

let booksDir* = getHomeDir() / "LFS-BOOKS-DEV"

proc contentLengthOf(headers: HttpHeaders): string =
  for key, val in headers.pairs:
    if key.toLowerAscii.strip() == "content-length":
      return val.strip()
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
          raise newException(IOError, url & " " & problem)
        return response
      if response.code.int < 500:
        raise newException(IOError, url & " answered HTTP " & $response.code)
      problem = "HTTP " & $response.code
    except CatchableError as error:
      # IOError propio: no reintentar 4xx, sí reintentar 5xx/red/corte.
      if error of IOError and "answered HTTP" in error.msg:
        raise
      problem = error.msg
    if attempt < 3:
      echo "  retry: " & problem
      sleep(1000)
  raise newException(IOError, url & " no se pudo bajar: " & problem)

proc hrefsIn*(index: string): seq[string] =
  ## El índice de descargas es un listado plano de <a href="...">.
  ## Acepta mayúsculas, espacios alrededor del =, comilla simple o doble,
  ## y decodifica &amp; para que la URL sea pedible.
  let low = index.toLowerAscii
  var i = 0
  while true:
    let h = low.find("href", i)
    if h < 0:
      break
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
    result.add index[j ..< k].replace("&amp;", "&")
    i = k + 1
