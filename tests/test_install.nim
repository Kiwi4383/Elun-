import std/[json, os, strutils, unittest]
import install

const packageInfo = """
<h3>Package Information</h3>
<ul>
<li>Download (HTTP): <a href="https://ejemplo.com/foo-1.5.tar.xz">https://ejemplo.com/foo-1.5.tar.xz</a></li>
<li>Download MD5 sum: abcdef1234567890abcdef1234567890</li>
</ul>
"""

const installBody = """
<h3>Installation of Foo</h3>
<p>Install Foo by running the following commands:</p>
<pre class="userinput">./configure --prefix=/usr &amp;&amp;
make</pre>
<p>To run the test suite, issue: <span>make check</span>.</p>
<pre class="userinput">make check</pre>
<p>Now, as the <code>root</code> user:</p>
<pre class="root">make install</pre>
<p>To run some simple verification tests, issue:</p>
<pre class="userinput">foo --trace https://www.example.com/</pre>
<h3>Command Explanations</h3>
"""

suite "instalación":
  test "unescapeEntities devuelve entidades":
    check unescapeEntities("a &amp;&amp; b &lt;c&gt; &quot;d&quot;") ==
      "a && b <c> \"d\""

  test "unescapeEntities deja el resto igual":
    check unescapeEntities("./configure --prefix=/usr") == "./configure --prefix=/usr"

  test "packageSource saca URL y MD5":
    let src = packageSource(packageInfo)
    check src.ok
    check src.url == "https://ejemplo.com/foo-1.5.tar.xz"
    check src.md5 == "abcdef1234567890abcdef1234567890"

  test "packageSource falla sin MD5":
    check not packageSource("<p>Download (HTTP): https://e.com/f.tar</p>").ok

  test "packageSource falla sin URL":
    check not packageSource("<p>Download MD5 sum: abc123</p>").ok

  test "installSection recorta la sección":
    let body = installSection("<h3>Intro</h3><p>x</p>" & installBody)
    check "Installation of Foo" notin body
    check "make install" in body
    check "Command Explanations" notin body

  test "installSection avisa si no hay sección":
    check installSection("<h3>Intro</h3><p>x</p>") == ""

  test "installSteps separa usuario y root en orden":
    let steps = installSteps(installSection("<h3>I</h3>" & installBody))
    check steps.len == 2
    check not steps[0].asRoot
    check "configure" in steps[0].code
    check steps[1].asRoot
    check steps[1].code == "make install"

  test "installSteps salta la test suite":
    let steps = installSteps(installSection("<h3>I</h3>" & installBody))
    check "make check" notin steps[0].code
    check steps.len == 2

  test "installSteps salta verificación con red":
    let steps = installSteps(installSection("<h3>I</h3>" & installBody))
    for s in steps:
      check "example.com" notin s.code

  test "installSteps conserva continuaciones":
    let steps = installSteps("<p>Run:</p><pre class=\"userinput\">./configure \\\n--prefix=/usr</pre>")
    check steps.len == 1
    check "\\\n--prefix" in steps[0].code

  test "findPrefix saca el prefijo del configure":
    check findPrefix(@["./configure --prefix=/usr \\\nmake"]) == "/usr"

  test "findPrefix vacío si no hay":
    check findPrefix(@["make", "make install"]) == ""

  test "formatDur en minutos y segundos":
    check formatDur(90) == "1m30s"
    check formatDur(45) == "45s"

  test "formatDur en horas":
    check formatDur(3661) == "1h1m"

  test "average promedia":
    check average(@[10i64, 20i64, 30i64]) == 20

  test "average vacío es cero":
    check average(@[]) == 0

  test "readRecords ordena y salta rotos":
    let dir = getTempDir() / "elun-test-recs"
    createDir(dir)
    writeFile(dir / "b.json", """{"name":"B","version":"1"}""")
    writeFile(dir / "a.json", """{"name":"a","version":"2"}""")
    writeFile(dir / "roto.json", "esto no es json")
    let recs = readRecords(dir)
    check recs.len == 2
    check recs[0]["name"].getStr() == "a"
    check recs[1]["name"].getStr() == "B"
    removeDir(dir)

  test "readRecords sin directorio es vacío":
    check readRecords(getTempDir() / "elun-test-noexiste").len == 0

  test "installDests saca destino con flags pegadas":
    check installDests("install -Dm755 target/release/foo /zz-elun-a/") ==
      @["/zz-elun-a/foo"]

  test "installDests salta banderas con argumento":
    check installDests("install -c -m 644 ./w.info '/zz-elun-b'") ==
      @["/zz-elun-b"]

  test "installDests entiende -t dir":
    check installDests("install -t /zz-elun-c f1 f2") ==
      @["/zz-elun-c/f1", "/zz-elun-c/f2"]

  test "installDests ignora lo que no es install":
    check installDests("cp a b\nmkdir -p /x\ninstall -Dm755 f /zz-elun-d/") ==
      @["/zz-elun-d/f"]

  test "findUninstall ve regla make":
    let dir = getTempDir() / "elun-test-uninst"
    createDir(dir)
    writeFile(dir / "Makefile", "uninstall:\n\trm -f foo\n")
    let u = findUninstall(dir)
    check u.kind == "rule" and u.command == "make uninstall"
    check u.dir == dir
    removeDir(dir)

  test "findUninstall no inventa regla":
    let dir = getTempDir() / "elun-test-uninst2"
    createDir(dir)
    writeFile(dir / "Makefile", "all:\n\techo hi\n")
    check findUninstall(dir).kind == ""
    removeDir(dir)

  test "findUninstall ve manifiesto cmake":
    let dir = getTempDir() / "elun-test-uninst3"
    createDir(dir)
    writeFile(dir / "install_manifest.txt", "/usr/bin/foo\n")
    let u = findUninstall(dir)
    check u.kind == "manifest"
    check "install_manifest.txt" in u.command
    removeDir(dir)
