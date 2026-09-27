import std/[httpclient, os, osproc, strutils]
import common
import update_books

type
  Deps* = object
    build*, runtime*, optional*: seq[string]
  Found* = object
    book*, location*, section*, name*, version*: string
    chapter*: string
    deps*: Deps
    unknownDeps*: bool
  Section* = object
    level*: int
    title*, body*: string

# Encabezados que son avisos, no subsecciones, aunque el XSL los ponga como h.
const asides = ["note", "notes", "warning", "important", "caution", "tip"]

proc stripTags*(s: string): string =
  var dropping = false
  for c in s:
    if c == '<':
      dropping = true
    elif c == '>':
      dropping = false
    elif not dropping:
      result.add c

proc cleanText*(s: string): string =
  stripTags(s).replace("&nbsp;", " ").splitWhitespace().join(" ")

proc canonTags*(html: string): string =
  ## tidy parte los tags largos en varias líneas; acá se colapsan para que los
  ## find("<a "), find("<strong ...>") y demás funcionen siempre.
  var inTag = false
  for c in html:
    if c == '<':
      inTag = true
    if inTag and c in {' ', '\t', '\n', '\r', '\f'}:
      if result.len > 0 and result[^1] != ' ':
        result.add ' '
    else:
      result.add c
    if c == '>':
      inTag = false

proc sectionsOf*(html: string): seq[Section] =
  ## Parte el HTML por sus encabezados h1..h6, en orden. El cuerpo de cada uno
  ## llega hasta el próximo encabezado de su mismo nivel o superior, así que un
  ## capítulo incluye todas sus subsecciones.
  var marks: seq[tuple[level: int, start, content: int, title: string]]
  var i = 0
  while i < html.len - 4:
    if html[i] == '<' and i + 2 < html.len and html[i + 1] == 'h' and
        html[i + 2].isDigit:
      let level = ord(html[i + 2]) - ord('0')
      if level in 1 .. 6:
        let openEnd = html.find('>', i)
        let closeTag = "</h" & $level & ">"
        let closeStart = html.find(closeTag, openEnd)
        if openEnd > 0 and closeStart > 0:
          marks.add (level, i, closeStart + closeTag.len,
                      cleanText(html[openEnd + 1 ..< closeStart]))
          i = closeStart + closeTag.len
          continue
    inc i
  for k, m in marks:
    var stop = html.len
    for j in k + 1 ..< marks.len:
      if marks[j].level <= m.level:
        stop = marks[j].start
        break
    result.add Section(level: m.level, title: m.title,
                       body: html[m.content ..< stop])

proc linkTexts*(body: string): seq[string] =
  var i = body.find("<a")
  while i >= 0:
    if i + 2 < body.len and body[i + 2] in {'>', ' ', '\t', '\n', '\r', '\f'}:
      let b = body.find('>', i)
      let c = if b > 0: body.find("</a>", b) else: -1
      if b > 0 and c > b:
        let t = cleanText(body[b + 1 ..< c])
        if t != "" and t notin result:
          result.add t
        i = c + 4
        continue
    i = body.find("<a", i + 2)

proc splitNameVersion*(s: string): tuple[name, version: string] =
  var i = s.len - 1
  while i > 0:
    if s[i] == '-' and i + 1 < s.len and s[i + 1].isDigit:
      return (s[0 ..< i], s[i + 1 .. ^1])
    dec i
  return (s, "")

proc matchHeading*(raw, query: string): tuple[ok: bool, name, version: string] =
  ## "8.22. Binutils-2.47" y "cURL-8.21.0" valen; "Appendix C. Dependencies"
  ## no, porque no trae versión. El " - Pass 1" de LFS no es parte del nombre.
  var t = cleanText(raw)
  # Solo se saca la numeración "8.22. " con su espacio: un nombre que empiece
  # con dígito, como 7Zip, no se toca.
  var i = 0
  while i < t.len and (t[i].isDigit or t[i] == '.'):
    inc i
  if i > 0 and i < t.len and t[i] == ' ':
    t = t[i .. ^1].strip()
  elif i >= t.len:
    return (false, "", "")
  const passMarker = " - Pass "
  let p = t.find(passMarker)
  if p >= 0:
    t = t[0 ..< p].strip()
  let (name, rawVersion) = splitNameVersion(t)
  # La versión es el primer token con forma de versión ("2.25" en
  # "Which-2.25 and Alternatives"). Si no hay, no es un capítulo de paquete.
  let tokens = rawVersion.splitWhitespace()
  if tokens.len == 0:
    return (false, "", "")
  let version = tokens[0]
  if not version[0].isDigit:
    return (false, "", "")
  let (qname, qver) = splitNameVersion(query)
  if name.toLowerAscii != qname.toLowerAscii:
    return (false, "", "")
  if qver != "" and qver != version:
    return (false, "", "")
  return (true, name, version)

proc splitItems*(s: string): seq[string] =
  for part in stripTags(s).replace(" and ", ",").split(','):
    let t = part.strip()
    if t != "" and t notin result:
      result.add t

proc appendixDeps*(path, name: string): tuple[deps: Deps, found: bool] =
  ## Apéndice C de LFS/MLFS: entradas <h2>/<h3>Nombre</h3> con pares
  ## "Installation depends on:" / "Required at runtime:" / ...
  let html = canonTags(readFile(path))
  for s in sectionsOf(html):
    if s.level in [2, 3] and s.title.toLowerAscii == name.toLowerAscii:
      var deps: Deps
      var rest = s.body
      while true:
        let a = rest.find("<strong class=\"segtitle\">")
        if a < 0: break
        let b = rest.find("</strong>", a)
        if b < 0: break
        let label = cleanText(rest[a ..< b])
        let c = rest.find("<span class=\"segbody\">", b)
        if c < 0: break
        let d = rest.find("</span>", c)
        if d < 0: break
        let items = splitItems(rest[c ..< d])
        if label == "Installation depends on:":
          deps.build.add items
        elif label == "Required at runtime:":
          deps.runtime.add items
        elif label in ["Test suite depends on:", "Optional dependencies:"]:
          deps.optional.add items
        rest = rest[d + 7 .. ^1]
      return (deps, true)
  return (Deps(), false)

proc addUnique*(s: var seq[string], items: seq[string]) =
  for it in items:
    if it notin s:
      s.add it

proc classify*(deps: var Deps, sub: string, items: seq[string]) =
  ## Required y Recommended hacen falta para compilar; lo marcado como runtime
  ## hace falta para funcionar; el resto es opcional. Los avisos no son
  ## subsecciones aunque vengan como encabezado.
  if sub.toLowerAscii in asides:
    return
  let low = sub.toLowerAscii
  if "runtime" in low:
    deps.runtime.addUnique items
  elif "test" in low or "option" in low:
    deps.optional.addUnique items
  else:
    deps.build.addUnique items

proc detailBlocks*(body: string): seq[tuple[title, content: string]] =
  ## GLFS/SLFS meten las subsecciones en <details><summary>Sub</summary>.
  var rest = body
  while true:
    let a = rest.find("<details")
    if a < 0: break
    let b = rest.find('>', a)
    if b < 0: break
    let c = rest.find("</details>", b)
    if c < 0: break
    let inner = rest[b + 1 ..< c]
    let s1 = inner.find("<summary>")
    let s2 = if s1 >= 0: inner.find("</summary>", s1) else: -1
    if s1 >= 0 and s2 > s1:
      result.add (cleanText(inner[s1 + 9 ..< s2]), inner[s2 + 10 .. ^1])
    rest = rest[c + 10 .. ^1]

proc blfsDepsOn*(html: string): tuple[deps: Deps, found: bool] =
  ## Sección "<Nombre> Dependencies" de BLFS/GLFS/SLFS, con subsecciones
  ## Required, Recommended, Recommended at runtime, Optional, ...
  let sections = sectionsOf(html)
  for k, s in sections:
    if s.level in 2 .. 4 and s.title.toLowerAscii.endsWith("dependencies") and
        s.title.len > len("dependencies"):
      var deps: Deps
      var j = k + 1
      # Un Note/Warning no cierra la sección en ningún nivel: se salta y se
      # sigue. Cualquier otro encabezado de nivel igual o superior sí la cierra.
      while j < sections.len and (sections[j].level > s.level or
          sections[j].title.toLowerAscii in asides):
        let sub = sections[j].title
        if sections[j].level == s.level + 1:
          classify(deps, sub, linkTexts(sections[j].body))
        inc j
      for d in detailBlocks(s.body):
        classify(deps, d.title, linkTexts(d.content))
      return (deps, true)
  return (Deps(), false)

proc withDeps*(book, location, section, name, version, html,
               appendix: string): Found =
  ## Required y Recommended hacen falta para compilar; lo marcado como runtime
  ## hace falta para funcionar; el resto es opcional.
  result = Found(book: book, location: location, section: section,
                 name: name, version: version, chapter: html)
  let blfs = blfsDepsOn(html)
  if blfs.found:
    result.deps = blfs.deps
  if appendix != "" and fileExists(appendix):
    # El apéndice completa lo que el capítulo no trae.
    let entry = appendixDeps(appendix, name)
    if entry.found:
      if result.deps.build.len == 0:
        result.deps.build = entry.deps.build
      if result.deps.runtime.len == 0:
        result.deps.runtime = entry.deps.runtime
      if result.deps.optional.len == 0:
        result.deps.optional = entry.deps.optional
      return
  if blfs.found:
    return
  result.unknownDeps = true

proc relPath*(path: string): string =
  if path.startsWith(booksDir):
    return path[len(booksDir) + 1 .. ^1]
  return path

proc searchNochunks*(book, path, query: string): seq[Found] =
  if not fileExists(path):
    return
  let html = canonTags(readFile(path))
  # Solo el apéndice C de LFS/MLFS usa anclas "xxx-dep" en sus entradas.
  let lfsKind = "-dep\"" in html
  let location = relPath(path)
  for s in sectionsOf(html):
    if s.level notin [1, 2]:
      continue
    let m = matchHeading(s.title, query)
    if not m.ok or "class=\"package\"" notin s.body:
      continue
    if lfsKind:
      result.add withDeps(book, location, s.title, m.name, m.version, s.body,
                          path)
    else:
      result.add withDeps(book, location, s.title, m.name, m.version, s.body,
                          "")

proc searchChunked*(book, dir, appendix, query: string): seq[Found] =
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    if not path.endsWith(".html"):
      continue
    let html = canonTags(readFile(path))
    if "class=\"package\"" notin html:
      continue
    for h in sectionsOf(html):
      if h.level != 1:
        continue
      let m = matchHeading(h.title, query)
      if m.ok:
        result.add withDeps(book, relPath(path), h.title,
                            m.name, m.version, html, appendix)
        break

proc searchOnce(query: string): seq[Found] =
  result.add searchNochunks("LFS development",
                            booksDir / "LFS" / "LFS-development.html", query)
  result.add searchChunked("BLFS development",
                           booksDir / "BLFS" / "BLFS-development-systemd",
                           "", query)
  result.add searchChunked("MLFS development", booksDir / "MLFS" / "html",
                           booksDir / "MLFS" / "html" / "appendices" /
                             "dependencies.html", query)
  result.add searchChunked("GLFS development", booksDir / "GLFS" / "html",
                           "", query)
  result.add searchChunked("SLFS development", booksDir / "SLFS" / "html",
                           "", query)
  result.add searchNochunks("LFS stable",
                            booksDir / "LFS" / "LFS-stable-systemd.html",
                            query)
  result.add searchNochunks("BLFS stable",
                            booksDir / "BLFS" / "BLFS-stable-systemd.html",
                            query)

proc bookPresent(book, name: string): bool =
  fileExists(booksDir / book / name)

proc syncRenderedIfStale(book, repo, branch, targets, rev: string): bool =
  ## git ls-remote dice la revisión remota sin bajar objetos: si no coincide
  ## con el checkout, hay libro nuevo.
  let checkout = booksDir / book
  if not dirExists(checkout / ".git"):
    return false
  let local = execCmdEx("git rev-parse HEAD",
                        workingDir = checkout).output.strip()
  let former = if branch != "": branch else: "HEAD"
  let remoteOut = execCmdEx("git ls-remote " & repo & " " & former,
                            workingDir = booksDir)
  if remoteOut.exitCode != 0:
    return false
  let remote = remoteOut.output.splitWhitespace()
  if remote.len == 0 or remote[0] == local:
    return false
  syncRenderedBook(book, repo, branch, targets, rev)
  return true

proc refreshIfStale(client: HttpClient): bool =
  for (book, name, indexUrl) in indexBooks:
    if bookPresent(book, name) and
        syncIndexBookIfChanged(client, book, name, indexUrl):
      result = true
  if dirExists(booksDir / "BLFS" / "BLFS-development-systemd") and
      syncBlfsDevIfChanged(client):
    result = true
  for (book, repo, branch, targets, rev) in renderedBooks:
    if syncRenderedIfStale(book, repo, branch, targets, rev):
      result = true

proc findPackage*(pkg: string): seq[Found] =
  if not dirExists(booksDir):
    echo "no hay libros: corré `elun update-books` primero"
    return @[]
  result = searchOnce(pkg)
  if result.len == 0:
    echo pkg & ": no está en los libros, buscando libros nuevos..."
    let client = newHttpClient(userAgent = "elun")
    if refreshIfStale(client):
      result = searchOnce(pkg)
    client.close()
  if result.len == 0:
    echo "aviso: " & pkg & " no existe en los libros"

proc printFound*(found: seq[Found]) =
  for f in found:
    echo f.name & "-" & f.version & " está en " & f.book & " (" &
         f.location & ", " & f.section & ")"
    if f.unknownDeps:
      echo "  dependencias: el capítulo no trae la lista, se desconocen"
    elif f.deps.build.len == 0 and f.deps.runtime.len == 0 and
        f.deps.optional.len == 0:
      echo "  dependencias: ninguna"
    else:
      if f.deps.build.len > 0:
        echo "  para compilar: " & f.deps.build.join(", ")
      if f.deps.runtime.len > 0:
        echo "  para funcionar: " & f.deps.runtime.join(", ")
      if f.deps.optional.len > 0:
        echo "  opcionales: " & f.deps.optional.join(", ")
