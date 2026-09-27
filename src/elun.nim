import std/os
import update_books
import search

const usage = """
Elun - instalador de paquetes guiado por los libros de Linux From Scratch

Uso:
  elun install <paquete>
  elun update <paquete>
  elun update-books
  elun remove <paquete>
  elun orphans
"""

proc needName(command: string): bool =
  if paramCount() < 2:
    echo "elun " & command & " necesita el nombre del paquete"
    return true
  return false

proc main(): int =
  if paramCount() == 0:
    echo usage
    return 1

  let command = paramStr(1)

  case command
  of "-h", "--help", "help":
    echo usage
  of "install", "update":
    if needName(command):
      return 1
    report(paramStr(2))
  of "update-books":
    updateBooks()
  of "remove":
    if needName("remove"):
      return 1
    echo "remove " & paramStr(2) & ": todavia no implementado"
  of "orphans":
    echo "orphans: todavia no implementado"
  else:
    echo "comando desconocido: " & command
    echo usage
    return 1

  return 0

when isMainModule:
  quit(main())
