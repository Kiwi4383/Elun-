import std/[strutils, unittest]
import search

suite "texto html":
  test "stripTags saca tags simples":
    check stripTags("<p>Hola</p>") == "Hola"

  test "stripTags saca tags anidados":
    check stripTags("<div><p>Hola <b>mundo</b></p></div>") == "Hola mundo"

  test "stripTags no toca entidades":
    check stripTags("<p>a &amp; b</p>") == "a &amp; b"

  test "cleanText colapsa espacios y nbsp":
    check cleanText("  8.22.&nbsp; Binutils-2.47  ") == "8.22. Binutils-2.47"

  test "canonTags une tags partidos":
    check canonTags("<a href=\n\"#x\">t</a>") == "<a href= \"#x\">t</a>"

  test "canonTags no toca el texto":
    check canonTags("<p>línea uno\nlínea dos</p>") ==
      "<p>línea uno\nlínea dos</p>"

  test "sectionsOf incluye subsecciones en el capítulo":
    let html = "<h2>Cap</h2><p>a</p><h3>Sub</h3><p>b</p><h2>Otro</h2>"
    let sections = sectionsOf(html)
    check sections.len == 3
    check sections[0].title == "Cap"
    check "Sub" in sections[0].body
    check sections[2].title == "Otro"

  test "sectionsOf separa capítulos hermanos":
    let html = "<h2>Uno</h2><p>a</p><h2>Dos</h2><p>b</p>"
    let sections = sectionsOf(html)
    check sections.len == 2
    check "a" in sections[0].body
    check "b" notin sections[0].body

  test "sectionsOf guarda los niveles":
    let html = "<h1>A</h1><h2>B</h2><h4>C</h4>"
    let sections = sectionsOf(html)
    check sections[0].level == 1
    check sections[1].level == 2
    check sections[2].level == 4

  test "linkTexts junta dos enlaces":
    check linkTexts("<p><a href=\"#a\">uno-1.0</a> and <a href=\"#b\">dos</a></p>") ==
      @["uno-1.0", "dos"]

  test "linkTexts no duplica y pasa attrs multilínea":
    check linkTexts("<a class=\"x\"\nhref=\"#a\">uno</a> <a href=\"#a\">uno</a>") ==
      @["uno"]

  test "linkTexts salta anclas vacías":
    check linkTexts("<a id=\"x\" name=\"x\"></a><a href=\"#a\">uno</a>") ==
      @["uno"]

  test "splitNameVersion parte nombre y versión":
    check splitNameVersion("cURL-8.22.0") == ("cURL", "8.22.0")

  test "splitNameVersion aguanta varios guiones":
    check splitNameVersion("make-ca-1.16.1") == ("make-ca", "1.16.1")

  test "splitNameVersion sin versión devuelve vacío":
    check splitNameVersion("Appendix C. Dependencies") ==
      ("Appendix C. Dependencies", "")

  test "matchHeading acepta capítulo numerado LFS":
    let m = matchHeading("8.22. Binutils-2.47", "binutils")
    check m.ok and m.name == "Binutils" and m.version == "2.47"

  test "matchHeading acepta capítulo BLFS sin número":
    let m = matchHeading("cURL-8.21.0", "curl")
    check m.ok and m.version == "8.21.0"

  test "matchHeading ignora el Pass de LFS":
    let m = matchHeading("5.2. Binutils-2.47 - Pass 1", "BINUTILS")
    check m.ok and m.name == "Binutils"

  test "matchHeading no distingue mayúsculas":
    check matchHeading("cURL-8.21.0", "CURL").ok

  test "matchHeading filtra por versión pedida":
    check matchHeading("cURL-8.21.0", "curl-8.21.0").ok
    check not matchHeading("cURL-8.21.0", "curl-8.22.0").ok
    check not matchHeading("Appendix C. Dependencies", "dependencies").ok

  test "matchHeading recorta títulos verborrágicos":
    let m = matchHeading("Which-2.25 and Alternatives", "which")
    check m.ok and m.name == "Which" and m.version == "2.25"
