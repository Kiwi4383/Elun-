import std/unittest
import elun

suite "cli args":
  test "version flag reconocido":
    check isVersionFlag("--version")
    check isVersionFlag("-v")
    check not isVersionFlag("install")

  test "comandos con nombre exigen 2 args":
    check validateArgs("install", 2)
    check validateArgs("search", 2)
    check not validateArgs("install", 1)
    check not validateArgs("install", 3)

  test "comandos sin nombre exigen 1 arg":
    check validateArgs("list", 1)
    check validateArgs("update-books", 1)
    check not validateArgs("list", 2)

  test "version consta":
    check elunVersion == "0.1.0"
