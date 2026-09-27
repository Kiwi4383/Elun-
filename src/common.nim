import std/[httpclient, os, strutils]

let booksDir* = getHomeDir() / "LFS-BOOKS-DEV"

proc fetch*(client: HttpClient, url: string): Response =
  ## El script de referencia usa curl --retry 3 y std/httpclient no reintenta,
  ## así que el reintento va acá. Un 4xx no se reintenta: no va a empezar a
  ## contestar 200.
  var problem = "sin respuesta"
  for attempt in 1 .. 3:
    try:
      let response = client.get(url)
      if response.code == Http200:
        # Toda descarga pasa por acá, así que el chequeo contra archivo
        # cortado va acá y cubre los libros, los índices y las páginas.
        if response.headers.hasKey("content-length") and
            response.headers["content-length"] != $response.body.len:
          echo "ERROR: " & url & " llegó cortado (" & $response.body.len &
               " de " & response.headers["content-length"] & " bytes)"
          quit(1)
        return response
      if response.code.int < 500:
        echo "ERROR: " & url & " answered HTTP " & $response.code
        quit(1)
      problem = "HTTP " & $response.code
    except CatchableError as error:
      problem = error.msg
    if attempt < 3:
      echo "  retry: " & problem
      sleep(1000)
  echo "ERROR: " & url & " no se pudo bajar: " & problem
  quit(1)

proc hrefsIn*(index: string): seq[string] =
  ## El índice de descargas es un listado plano de <a href="...">, así que no
  ## hace falta un parser de HTML para sacarle los nombres.
  for chunk in index.split("href=\"")[1 .. ^1]:
    result.add chunk.split('"')[0]
