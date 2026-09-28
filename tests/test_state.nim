import std/[os, tables, unittest]
import update_books

suite "manifiestos":
  test "safeHref acepta rutas internas":
    check safeHref("basicnet/curl.html")
    check safeHref("index.html")

  test "safeHref rechaza escape":
    check not safeHref("/etc/passwd")
    check not safeHref("../afuera.html")
    check not safeHref("sub/../../afuera.html")
  test "recordHash guarda el digest nuevo":
    var hashes = initTable[string, string]()
    check recordHash(hashes, "a.html", "contenido")
    check hashes["a.html"].len == 64

  test "recordHash avisa si cambió":
    var hashes = initTable[string, string]()
    discard recordHash(hashes, "a.html", "uno")
    check recordHash(hashes, "a.html", "dos")

  test "recordHash calla si está igual":
    var hashes = initTable[string, string]()
    discard recordHash(hashes, "a.html", "uno")
    check not recordHash(hashes, "a.html", "uno")

  test "hashes van y vienen intactos":
    let dir = getTempDir() / "elun-test-hashes"
    createDir(dir)
    var hashes = initTable[string, string]()
    hashes["b.html"] = "abc123"
    saveHashes(dir, hashes)
    let back = loadHashes(dir)
    check back["b.html"] == "abc123"
    writeFile(dir / ".elun-hashes",
      readFile(dir / ".elun-hashes") & "línea rota sin dos partes\n")
    check loadHashes(dir)["b.html"] == "abc123"
    removeDir(dir)

  test "sources van y vienen intactas":
    let dir = getTempDir() / "elun-test-sources"
    createDir(dir)
    var sources = initTable[string, string]()
    sources["https://ejemplo.com/i/"] = "LIBRO.html"
    writeSources(dir, sources)
    check readSources(dir)["https://ejemplo.com/i/"] == "LIBRO.html"
    removeDir(dir)
