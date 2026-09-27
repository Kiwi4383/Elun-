import std/[os, strutils, unittest]
import search

const appendixFixture = """
<h3><a id="foo-dep" name="foo-dep"></a>Foo</h3>
<div class="segmentedlist">
<div class="seg"><strong class="segtitle">Installation depends on:</strong>
<span class="segbody">Bash, GCC and Make</span></div>
<div class="seg"><strong class="segtitle">Required at runtime:</strong>
<span class="segbody">Glibc</span></div>
<div class="seg"><strong class="segtitle">Test suite depends on:</strong>
<span class="segbody">DejaGNU</span></div>
<div class="seg"><strong class="segtitle">Optional dependencies:</strong>
<span class="segbody">Jansson</span></div>
</div>
<h3><a id="bar-dep" name="bar-dep"></a>Bar</h3>
"""

const blfsFixture = """
<h1>Foo-1.5</h1>
<div class="package"><p>The Foo package.</p></div>
<h3>Foo Dependencies</h3>
<h4>Required</h4>
<p><a href="#a">liba-1.0</a></p>
<h4>Recommended</h4>
<p><a href="#b">libb-2.0</a></p>
<h3>Note</h3>
<p>Un aviso con <a href="#n">un enlace</a> que no es dependencia.</p>
<h4>Recommended at runtime</h4>
<p><a href="#c">libc-3.0</a></p>
<h4>Optional</h4>
<p><a href="#d">libd-4.0</a></p>
<h3>Installation of Foo</h3>
"""

const detailsFixture = """
<h1>Qux-2.0</h1>
<div class="package"><p>The Qux package.</p></div>
<h3>Qux Dependencies</h3>
<details open="true"><summary>Required</summary>
<p><a href="#a">liba-1.0</a></p>
</details>
<details><summary>Optional</summary>
<p><a href="#z">libz-9.0</a></p>
</details>
<h3>Installation of Qux</h3>
"""

proc writeTmp(dir, name, content: string): string =
  createDir(dir)
  result = dir / name
  writeFile(result, content)

suite "dependencias":
  test "splitItems parte por comas":
    check splitItems("Bash, GCC, Make") == @["Bash", "GCC", "Make"]

  test "splitItems parte por and":
    check splitItems("Bash and GCC") == @["Bash", "GCC"]

  test "splitItems saca vacíos y duplicados":
    check splitItems("Bash,, Bash and ") == @["Bash"]

  test "addUnique agrega lo nuevo y salta lo visto":
    var s = @["a"]
    s.addUnique(@["a", "b"])
    check s == @["a", "b"]

  test "classify Required va a compilar":
    var deps: Deps
    classify(deps, "Required", @["liba-1.0"])
    check deps.build == @["liba-1.0"]

  test "classify Recommended va a compilar":
    var deps: Deps
    classify(deps, "Recommended", @["libb-2.0"])
    check deps.build == @["libb-2.0"]

  test "classify runtime va a funcionar":
    var deps: Deps
    classify(deps, "Recommended at runtime", @["libc-3.0"])
    check deps.runtime == @["libc-3.0"]

  test "classify Optional queda opcional":
    var deps: Deps
    classify(deps, "Optional", @["libd-4.0"])
    check deps.optional == @["libd-4.0"]

  test "classify test suite queda opcional":
    var deps: Deps
    classify(deps, "Optional if Running the Test Suite", @["libt-1.0"])
    check deps.optional == @["libt-1.0"]

  test "classify ignora avisos":
    var deps: Deps
    classify(deps, "Note", @["algo-1.0"])
    check deps.build.len == 0 and deps.runtime.len == 0 and
      deps.optional.len == 0

  test "detailBlocks saca título y contenido":
    let blocks = detailBlocks(detailsFixture)
    check blocks.len == 2
    check blocks[0].title == "Required"
    check "liba-1.0" in blocks[0].content

  test "detailBlocks salta details sin summary":
    check detailBlocks("<details><p>sin summary</p></details>").len == 0

  test "appendixDeps lee compilar y funcionar":
    let dir = getTempDir() / "elun-test-appendix"
    let path = writeTmp(dir, "dependencies.html", appendixFixture)
    let res = appendixDeps(path, "foo")
    check res.found
    check res.deps.build == @["Bash", "GCC", "Make"]
    check res.deps.runtime == @["Glibc"]
    removeDir(dir)

  test "appendixDeps lee opcionales y tests":
    let dir = getTempDir() / "elun-test-appendix2"
    let path = writeTmp(dir, "dependencies.html", appendixFixture)
    let res = appendixDeps(path, "Foo")
    check res.found
    check res.deps.optional == @["DejaGNU", "Jansson"]
    removeDir(dir)

  test "appendixDeps avisa si no hay entrada":
    let dir = getTempDir() / "elun-test-appendix3"
    let path = writeTmp(dir, "dependencies.html", appendixFixture)
    check not appendixDeps(path, "baz").found
    removeDir(dir)

  test "appendixDeps acepta entradas h2":
    let dir = getTempDir() / "elun-test-appendix4"
    let path = writeTmp(dir, "d.html",
      "<h2><a id=\"w-dep\"></a>W</h2>" &
      "<strong class=\"segtitle\">Installation depends on:</strong>" &
      "<span class=\"segbody\">Bash</span>")
    let res = appendixDeps(path, "w")
    check res.found and res.deps.build == @["Bash"]
    removeDir(dir)

  test "blfsDepsOn lee la sección completa":
    let res = blfsDepsOn(blfsFixture)
    check res.found
    check res.deps.build == @["liba-1.0", "libb-2.0"]
    check res.deps.runtime == @["libc-3.0"]
    check res.deps.optional == @["libd-4.0"]

  test "blfsDepsOn salta el Note sin perder lo que sigue":
    let res = blfsDepsOn(blfsFixture)
    check res.found
    check "un enlace" notin res.deps.build
    check res.deps.runtime.len == 1

  test "blfsDepsOn lee details de GLFS":
    let res = blfsDepsOn(detailsFixture)
    check res.found
    check res.deps.build == @["liba-1.0"]
    check res.deps.optional == @["libz-9.0"]

  test "blfsDepsOn avisa si no hay sección":
    check not blfsDepsOn("<h1>Foo-1.5</h1><p>nada</p>").found
