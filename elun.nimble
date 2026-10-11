version       = "0.1.0"
author        = "Sabrina"
description   = "Instalador de paquetes guiado por los libros de Linux From Scratch"
license       = "BSDZeroClauseLicense"
srcDir        = "src"
bin           = @["elun"]

requires "nim >= 2.2.0"
requires "libsha"

task test, "Run unit tests":
  for t in ["test_cli", "test_deps", "test_install", "test_parse",
            "test_search", "test_state"]:
    exec "nim c --path:src --hints:off -r tests/" & t & ".nim"
