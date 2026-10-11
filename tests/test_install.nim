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

  test "packageSource sin MD5 avisa pero vale":
    let src = packageSource("<li>Download: https://e.com/f.tar.xz</li>")
    check src.ok and src.md5 == ""
    check src.url == "https://e.com/f.tar.xz"

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

  test "installSteps exige clase root exacta":
    let steps = installSteps("<p>x</p><pre class=\"userinput\" data-rooted=\"1\">make</pre>")
    check steps.len == 1
    check not steps[0].asRoot

  test "isRootTag rechaza data-class":
    check not isRootTag("<pre data-class=\"root\">")
    check isRootTag("<pre class=\"root\">")
    check isRootTag("<pre class='user root'>")

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

  test "findPrefix acepta espacio y cmake":
    check findPrefix(@["./configure --prefix /opt"]) == "/opt"
    check findPrefix(@["cmake -DCMAKE_INSTALL_PREFIX=/usr ."]) == "/usr"
    check findPrefix(@["meson setup build --prefix /usr"]) == "/usr"

  test "findPrefix vacío si no hay":
    check findPrefix(@["make", "make install"]) == ""

  test "stepScript guarda y restaura cwd":
    let script = stepScript("make", "/tmp/x/.elun-cwd")
    check "set -e" in script
    check "cat" in script and "pwd >" in script
    check "SUDO_USER" in script

  test "stepScript confina cwd al build":
    let script = stepScript("make", "/tmp/x/.elun-cwd")
    check "dirname" in script
    check "fuera del build" in script

  test "cwd persiste entre pasos":
    let dir = getTempDir() / "elun-test-cwd"
    createDir(dir / "sub")
    runStep("t", (asRoot: false, code: "cd sub"), dir, 1, dir / ".elun-cwd")
    check readFile(dir / ".elun-cwd").strip() == dir / "sub"
    runStep("t", (asRoot: false, code: "pwd"), dir, 2, dir / ".elun-cwd")
    removeDir(dir)

  test "formatDur en minutos y segundos":
    check formatDur(90) == "1m30s"
    check formatDur(45) == "45s"

  test "formatDur en horas":
    check formatDur(3661) == "1h1m1s"

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

  test "orphansOf marca lo que nadie necesita":
    let noDeps: seq[string] = @[]
    check orphansOf(@[(name: "curl", deps: @["libpsl-1.0"]),
                      (name: "libpsl", deps: noDeps)]) == @["curl"]

  test "orphansOf normaliza versión y mayúsculas":
    let noDeps2: seq[string] = @[]
    check orphansOf(@[(name: "Foo", deps: noDeps2),
                      (name: "libpsl", deps: noDeps2)]) ==
      @["Foo", "libpsl"]
    check orphansOf(@[(name: "curl", deps: @["LIBPSL-0.23.3"]),
                      (name: "libpsl", deps: noDeps2)]) == @["curl"]

  test "orphansOf vacío es vacío":
    let none: seq[tuple[name: string, deps: seq[string]]] = @[]
    check orphansOf(none).len == 0

  test "safeName blinda traversals":
    check safeName("Foo Bar-1.0") == "Foo_Bar-1.0"
    check safeName("../../etc") == ".._.._etc"
    check safeName("..") == "_"

  test "filterByPrefix confina al prefijo":
    check filterByPrefix(@["/usr/bin/foo", "/etc/passwd"], "/usr") ==
      @["/usr/bin/foo"]
    check filterByPrefix(@["/usr/bin/foo"], "") == @["/usr/bin/foo"]

  test "filterByPrefix exige borde de directorio":
    check filterByPrefix(@["/usr-evil/foo", "/usrbin/x"], "/usr").len == 0
    check underPrefix("/usr", "/usr")
    check not underPrefix("/usr-evil/foo", "/usr")

  test "cmakePrefix lee el prefijo del cache":
    let dir = getTempDir() / "elun-test-cmake"
    createDir(dir)
    writeFile(dir / "CMakeCache.txt",
      "ALGO:STRING=x\nCMAKE_INSTALL_PREFIX:PATH=/opt/foo\n")
    check cmakePrefix(dir) == "/opt/foo"
    removeDir(dir)

  test "cmakePrefix vacío si no hay":
    check cmakePrefix(getTempDir() / "elun-test-noexiste") == ""

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

  test "installDests pela sudo y ruta absoluta de install":
    check installDests("sudo install -Dm755 f /zz-elun-e/") == @["/zz-elun-e/f"]
    check installDests("/usr/bin/install -Dm755 f /zz-elun-f/") ==
      @["/zz-elun-f/f"]

  test "installDests rechaza destino relativo":
    check installDests("install -Dm755 f rel/dir/f").len == 0

  test "installDests entiende --target-directory=":
    check installDests("install -Dm755 --target-directory=/zz-elun-g f1") ==
      @["/zz-elun-g/f1"]

  test "installDests salta cargo":
    check installDests("cargo install --path . --root /zz-elun-h").len == 0

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

  test "findUninstall no ejecuta make con shell":
    let dir = getTempDir() / "elun-test-uninst4"
    createDir(dir)
    writeFile(dir / "Makefile", "uninstall:\n\techo $(shell id)\n")
    check findUninstall(dir).kind == ""
    removeDir(dir)

  test "uninstallManifest exige prefijo":
    let dir = getTempDir() / "elun-test-manifest"
    createDir(dir)
    let target = dir / "victima.txt"
    writeFile(target, "x")
    let manifest = dir / "install_manifest.txt"
    writeFile(manifest, target & "\n")
    uninstallManifest("t", manifest, "", dir)
    check fileExists(target)
    removeDir(dir)
