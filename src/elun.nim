import std/os
import update_books
import search
import install

const elunVersion* = "0.1.0"

const usage = """
Elun - package installer guided by the Linux From Scratch books

Usage:
  elun install <package>
  elun update <package>
  elun update-books
  elun remove <package>
  elun orphans
  elun list
  elun search <package>
  elun --version
  elun -h | --help
"""

proc isVersionFlag*(cmd: string): bool =
  cmd in ["--version", "-v", "version"]

proc validateArgs*(command: string, count: int): bool =
  ## Pure helper, testable: count is paramCount().
  case command
  of "install", "update", "remove", "search":
    return count == 2
  of "list", "orphans", "update-books", "-h", "--help", "help",
     "--version", "-v", "version":
    return count == 1
  else:
    return false

proc needName(command: string): bool =
  if paramCount() < 2:
    echo "elun " & command & " needs the package name"
    return true
  if paramCount() > 2:
    echo "elun " & command & " takes exactly one package name"
    echo usage
    return true
  return false

proc rejectExtraArgs(command: string): bool =
  if paramCount() > 1:
    echo "elun " & command & " takes no arguments"
    echo usage
    return true
  return false

proc main(): int =
  if paramCount() == 0:
    echo usage
    return 1

  let command = paramStr(1)

  try:
    case command
    of "-h", "--help", "help":
      if rejectExtraArgs(command):
        return 1
      echo usage
    of "--version", "-v", "version":
      if rejectExtraArgs(command):
        return 1
      echo "elun " & elunVersion
    of "install", "update":
      if needName(command):
        return 1
      if command == "install":
        if not installPackage(paramStr(2)):
          return 1
      else:
        if not updatePackage(paramStr(2)):
          return 1
    of "update-books":
      if rejectExtraArgs(command):
        return 1
      updateBooks()
    of "remove":
      if needName("remove"):
        return 1
      if not removePackage(paramStr(2)):
        return 1
    of "orphans":
      if rejectExtraArgs(command):
        return 1
      listOrphans()
    of "list":
      if rejectExtraArgs(command):
        return 1
      listPackages()
    of "search":
      if needName("search"):
        return 1
      let found = findPackage(paramStr(2))
      printFound(found)
      if found.len == 0:
        return 1
    else:
      if isVersionFlag(command):
        echo "elun " & elunVersion
      else:
        echo "unknown command: " & command
        echo usage
        return 1
  except CatchableError as e:
    echo "ERROR: " & e.msg
    return 1

  return 0

when isMainModule:
  quit(main())
