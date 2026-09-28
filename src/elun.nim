import std/os
import update_books
import search
import install

const usage = """
Elun - instalador de paquetes guiado por los libros de Linux From Scratch

Uso:
  elun install <paquete>
  elun update <paquete>
  elun update-books
  elun remove <paquete>
  elun orphans
  elun list
  elun search <paquete>
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
    if command == "install":
      installPackage(paramStr(2))
    else:
      updatePackage(paramStr(2))
  of "update-books":
    updateBooks()
  of "remove":
    if needName("remove"):
      return 1
    removePackage(paramStr(2))
  of "orphans":
    listOrphans()
  of "list":
    listPackages()
  of "search":
    if needName("search"):
      return 1
    printFound(findPackage(paramStr(2)))
  else:
    echo "comando desconocido: " & command
    echo usage
    return 1

  return 0

when isMainModule:
  quit(main())
