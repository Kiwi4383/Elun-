import std/[os, strutils, unittest]
import search

const nochunksLfs = """
<h2>8.22.&nbsp;Binutils-2.47</h2>
<div class="package"><p>The Binutils package.</p></div>
<h2>8.23.&nbsp;Gmp-6.3.0</h2>
<div class="package"><p>The GMP package.</p></div>
"""

const nochunksBlfs = """
<h2 class="title">cURL-8.21.0</h2>
<div class="package"><p>The cURL package.</p></div>
<h4>cURL Dependencies</h4>
<h5>Required</h5>
<p><a href="#x">libpsl-0.23.3</a></p>
<h2 class="title">Wget-1.25.0</h2>
<div class="package"><p>The Wget package.</p></div>
"""

const chunkedPage = """
<h1>Foo-1.5</h1>
<div class="package"><p>The Foo package.</p></div>
<h3>Foo Dependencies</h3>
<h4>Required</h4>
<p><a href="#a">liba-1.0</a></p>
<h3>Installation of Foo</h3>
"""

proc writeTmp(dir, name, content: string): string =
  createDir(dir)
  result = dir / name
  writeFile(result, content)

suite "búsqueda":
  test "withDeps prefiere la sección del capítulo":
    let f = withDeps("B", "f.html", "cURL-8.21.0", "cURL", "8.21.0",
                     nochunksBlfs, "")
    check not f.unknownDeps
    check f.deps.build == @["libpsl-0.23.3"]

  test "withDeps avisa si no hay de dónde sacar":
    let f = withDeps("B", "f.html", "Foo-1.5", "Foo", "1.5",
                     "<h1>Foo-1.5</h1>", "")
    check f.unknownDeps

  test "searchNochunks encuentra el capítulo LFS":
    let dir = getTempDir() / "elun-test-nochunks"
    let path = writeTmp(dir, "LFS-test.html", nochunksLfs)
    let found = searchNochunks("LFS test", path, "gmp")
    check found.len == 1
    check found[0].name == "Gmp" and found[0].version == "6.3.0"
    removeDir(dir)

  test "searchNochunks encuentra el capítulo BLFS con deps":
    let dir = getTempDir() / "elun-test-nochunks2"
    let path = writeTmp(dir, "BLFS-test.html", nochunksBlfs)
    let found = searchNochunks("BLFS test", path, "curl")
    check found.len == 1
    check found[0].deps.build == @["libpsl-0.23.3"]
    removeDir(dir)

  test "searchChunked encuentra el archivo y usa el apéndice":
    let dir = getTempDir() / "elun-test-chunked"
    discard writeTmp(dir, "foo.html", chunkedPage)
    let appendix = writeTmp(dir, "deps.html",
      "<h3><a id=\"foo-dep\"></a>Foo</h3>" &
      "<strong class=\"segtitle\">Required at runtime:</strong>" &
      "<span class=\"segbody\">Glibc</span>")
    let found = searchChunked("T", dir, appendix, "foo")
    check found.len == 1
    check found[0].location.endsWith("foo.html")
    check found[0].deps.build == @["liba-1.0"]
    check found[0].deps.runtime == @["Glibc"]
    removeDir(dir)
