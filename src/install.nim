{.push warning[Deprecated]: off.}
import std/md5
{.pop.}
import std/[httpclient, json, os, osproc, strutils, times, algorithm]
import common
import search
import update_books

type Step = tuple[asRoot: bool, code: string]

let stateDir* = getHomeDir() / ".local" / "share" / "elun"

proc buildDirFor(name: string): string =
  stateDir / "build" / name

proc recordPathFor(name: string): string =
  stateDir / "installed" / name & ".json"

proc isRoot(): bool =
  try:
    return execCmdEx("id -u").output.strip() == "0"
  except CatchableError:
    return false

proc requireSudo(what: string) =
  if not isRoot() and findExe("sudo") == "":
    echo "ERROR: falta sudo, necesario para " & what
    quit(1)

proc requireInstallTools() =
  for tool in ["tar", "sh"]:
    if findExe(tool) == "":
      echo "ERROR: falta " & tool & ", necesario para instalar"
      quit(1)
  requireSudo("los pasos de root")

proc unescapeEntities*(s: string): string =
  result = s.replace("&amp;", "&").replace("&lt;", "<")
    .replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")

proc listItemAfter(html, label: string): string =
  ## Texto del <li> que contiene el rótulo.
  let a = html.find(label)
  if a < 0: return ""
  let b = html.find("</li>", a)
  if b < 0: return ""
  return cleanText(stripTags(html[a ..< b]))

proc packageSource*(html: string): tuple[url, md5: string, ok: bool] =
  ## "Download (HTTP)" y "Download MD5 sum" de la Package Information: el md5
  ## es el primer token hexadecimal de 32 del item.
  let raw = listItemAfter(html, "Download (HTTP):").splitWhitespace()
  let sums = listItemAfter(html, "Download MD5 sum:").splitWhitespace()
  if raw.len == 0 or sums.len == 0:
    return ("", "", false)
  for token in raw:
    if token.startsWith("http"):
      for s in sums:
        if s.len == 32 and s.allCharsInSet({'0' .. '9', 'a' .. 'f', 'A' .. 'F'}):
          return (token, s.toLowerAscii, true)
      return ("", "", false)
  return ("", "", false)

proc installSection*(html: string): string =
  for s in sectionsOf(html):
    if s.title.startsWith("Installation of "):
      return s.body
  return ""

proc installSteps*(body: string): seq[Step] =
  ## Los <pre> en orden con el <p> que los precede: userinput van como usuario
  ## y root con sudo. Los que siguen a un párrafo de tests se saltan, porque la
  ## fase 3 no corre suites.
  var i = 0
  var lastPara = ""
  while i < body.len:
    let p = body.find("<p", i)
    let r = body.find("<pre", i)
    if p < 0 and r < 0:
      break
    if p >= 0 and (r < 0 or p < r):
      let b = body.find('>', p)
      let c = body.find("</p>", b)
      if b < 0 or c < 0:
        break
      lastPara = cleanText(body[b + 1 ..< c]).toLowerAscii
      i = c + 4
    else:
      let b = body.find('>', r)
      let c = body.find("</pre>", b)
      if b < 0 or c < 0:
        break
      let tag = body[r .. b]
      if "test suite" notin lastPara and "verification test" notin lastPara:
        result.add (asRoot: "root" in tag,
                    code: unescapeEntities(stripTags(body[b + 1 ..< c])).strip())
      i = c + 6

proc findPrefix*(codes: seq[string]): string =
  for code in codes:
    let i = code.find("--prefix=")
    if i >= 0:
      let words = code[i + 9 .. ^1].splitWhitespace()
      if words.len > 0:
        return words[0].strip(chars = {'\\', '"', '\''})
  return ""

proc runStep(pkg: string, step: Step, workDir: string, n: int) =
  let script = workDir / ".elun-step-" & $n & ".sh"
  # set -u: los capítulos LFS usan variables como $LFS que acá no existen y
  # con nounset el script se corta en vez de expandir vacío.
  writeFile(script, "#!/bin/sh\nset -eu\n" & step.code & "\n")
  let who = if step.asRoot: "root" else: "user"
  echo "  [" & who & "] paso " & $n
  var command = "sh " & quoteShell(script)
  if step.asRoot and not isRoot():
    command = "sudo " & command
  let (output, code) = execCmdEx(command, workingDir = workDir)
  echo output
  if code != 0:
    echo "ERROR: paso " & $n & " falló en " & pkg
    quit(1)

proc checkMd5(path, expected: string) =
  let digest = ($toMD5(readFile(path))).toLowerAscii
  if digest != expected.toLowerAscii:
    echo "ERROR: " & path & " no coincide con el MD5 del libro"
    quit(1)

proc downloadSource(client: HttpClient, url, dest: string) =
  echo "Bajando fuente " & url
  writeFile(dest, fetch(client, url).body)

proc enterSource(workDir: string): string =
  ## El tarball suele traer un solo directorio: se entra en él.
  var dirs: seq[string]
  for kind, path in walkDir(workDir):
    if kind == pcDir:
      dirs.add path
  if dirs.len == 1:
    return dirs[0]
  return workDir

proc unpack(pkg, dest: string): string =
  if dest.endsWith(".zip"):
    if findExe("unzip") == "":
      echo "ERROR: falta unzip, necesario para " & dest
      quit(1)
    run(pkg, dest.parentDir, "unzip -o -q " & quoteShell(dest))
  else:
    run(pkg, dest.parentDir, "tar -xf " & quoteShell(dest))
  return enterSource(dest.parentDir)

proc writeRecord(f: Found, url, md5, prefix: string, secs: int64) =
  createDir(stateDir / "installed")
  let rec = %*{
    "name": f.name, "version": f.version, "book": f.book,
    "location": f.location, "date": now().format("yyyy-MM-dd HH:mm"),
    "source": url, "md5": md5, "prefix": prefix, "seconds": secs}
  writeFile(recordPathFor(f.name), $rec)

proc formatDur*(secs: int64): string =
  let h = secs div 3600
  let m = (secs mod 3600) div 60
  let s = secs mod 60
  if h > 0:
    return $h & "h" & $m & "m"
  if m > 0:
    return $m & "m" & $s & "s"
  return $s & "s"

proc average*(secs: seq[int64]): int64 =
  if secs.len == 0:
    return 0
  var total: int64 = 0
  for s in secs:
    total += s
  return total div int64(secs.len)

proc recName(r: JsonNode): string =
  r.getOrDefault("name").getStr("")

proc readRecords*(dir: string): seq[JsonNode] =
  if not dirExists(dir):
    return @[]
  for path in walkFiles(dir / "*.json"):
    try:
      result.add parseJson(readFile(path))
    except CatchableError:
      discard
  result.sort(proc(a, b: JsonNode): int =
    cmp(recName(a).toLowerAscii, recName(b).toLowerAscii))

proc listPackages*() =
  let recs = readRecords(stateDir / "installed")
  if recs.len == 0:
    echo "no hay paquetes instalados"
    return
  for r in recs:
    var line = recName(r) & "-" & r.getOrDefault("version").getStr("?") &
      "  " & r.getOrDefault("book").getStr("?")
    if r.hasKey("seconds"):
      line.add "  " & formatDur(r["seconds"].getInt(0).int64)
    echo line

proc findRecord*(name: string): string =
  ## Ruta del registro instalado, sin distinguir mayúsculas.
  if not dirExists(stateDir / "installed"):
    return ""
  for path in walkFiles(stateDir / "installed" / "*.json"):
    if path.splitFile().name.toLowerAscii == name.toLowerAscii:
      return path
  return ""

proc recordDurations(): seq[int64] =
  if not dirExists(stateDir / "installed"):
    return @[]
  for path in walkFiles(stateDir / "installed" / "*.json"):
    try:
      let rec = parseJson(readFile(path))
      if rec.hasKey("seconds"):
        result.add rec["seconds"].getInt().int64
    except CatchableError:
      discard

proc buildAndRecord(f: Found, url, md5: string): int64 =
  let t0 = now()
  let dir = buildDirFor(f.name)
  createDir(dir)
  let tarball = dir / url.split('/')[^1]
  let client = newHttpClient(userAgent = "elun")
  if not fileExists(tarball):
    downloadSource(client, url, tarball)
  checkMd5(tarball, md5)
  client.close()
  let srcDir = unpack(f.name, tarball)
  let steps = installSteps(installSection(f.chapter))
  if steps.len == 0:
    echo "ERROR: el capítulo no trae comandos de instalación"
    quit(1)
  var codes: seq[string]
  for i, step in steps:
    runStep(f.name, step, srcDir, i + 1)
    if not step.asRoot:
      codes.add step.code
  let secs = (now() - t0).inSeconds
  writeRecord(f, url, md5, findPrefix(codes), secs)
  return secs

proc buildFromFound(f: Found, action: string) =
  let src = packageSource(f.chapter)
  if not src.ok:
    echo "ERROR: el capítulo no trae descarga verificable con MD5"
    quit(1)
  let secs = buildAndRecord(f, src.url, src.md5)
  echo action & ": " & f.name & "-" & f.version & " (tardó " &
    formatDur(secs) & ", promedio " & formatDur(average(recordDurations())) &
    ")"

proc installPackage*(pkg: string) =
  requireInstallTools()
  let found = findPackage(pkg)
  if found.len == 0:
    return
  # La búsqueda ya viene en orden developer primero: se instala la primera.
  let f = found[0]
  printFound(@[f])
  echo f.name & "-" & f.version & " de " & f.book & ": instalando"
  buildFromFound(f, "instalado")

proc updatePackage*(pkg: string) =
  requireInstallTools()
  let recPath = findRecord(pkg)
  if recPath == "":
    echo pkg & ": no está instalado, usá `elun install` primero"
    return
  let rec = parseJson(readFile(recPath))
  let found = findPackage(rec["name"].getStr())
  if found.len == 0:
    return
  let f = found[0]
  if f.version == rec["version"].getStr():
    echo f.name & " ya está en la última versión (" & f.version & ")"
    return
  # Se compila encima sin borrar la carpeta, como pide el doc.
  echo f.name & " " & rec["version"].getStr() & " -> " & f.version &
    " de " & f.book & ": actualizando"
  buildFromFound(f, "actualizado")

proc elevate(command: string): string =
  ## sudo salvo que ya se sea root.
  if isRoot():
    return command
  requireSudo("desinstalar")
  return "sudo " & command

proc hasTarget(dir, tool, makefile, target: string): bool =
  ## `make -n`/`ninja -n` solo preguntan: no ejecutan nada.
  if not fileExists(dir / makefile):
    return false
  try:
    return execCmdEx(tool & " -n " & target,
                     workingDir = dir).exitCode == 0
  except CatchableError:
    return false

proc findUninstall*(srcDir: string): tuple[kind, dir, command: string] =
  ## Cómo desinstalar: regla del Makefile, manifiesto de cmake o nada. El
  ## manifiesto cubre a cmake, que genera Makefiles con install pero sin
  ## uninstall.
  for sub in ["", "build"]:
    let dir = if sub == "": srcDir else: srcDir / sub
    if hasTarget(dir, "make", "Makefile", "uninstall"):
      return ("rule", dir, "make uninstall")
    if hasTarget(dir, "ninja", "build.ninja", "uninstall"):
      return ("rule", dir, "ninja uninstall")
  for sub in ["", "build"]:
    let dir = if sub == "": srcDir else: srcDir / sub
    if fileExists(dir / "install_manifest.txt"):
      return ("manifest", dir,
              "xargs rm < " & quoteShell(dir / "install_manifest.txt"))
  return ("", "", "")

proc installDests*(code: string): seq[string] =
  ## Destinos concretos de los `install` del capítulo (capítulos cargo). Las
  ## banderas se saltan (-m/-o/-g comen el siguiente token) y -t dir invierte.
  for line in code.splitLines():
    let tokens = line.strip().splitWhitespace()
    if tokens.len < 3 or tokens[0] != "install":
      continue
    var sources: seq[string]
    var dest = ""
    var destIsDir = false
    var i = 1
    while i < tokens.len:
      let t = tokens[i].strip(chars = {'\'', '"'})
      if t == "-t" and i + 1 < tokens.len:
        dest = tokens[i + 1].strip(chars = {'\'', '"'})
        destIsDir = true
        inc i, 2
      elif t.len > 0 and t[0] == '-':
        inc i
        if t in ["-m", "-o", "-g"] and i < tokens.len:
          inc i
      else:
        sources.add t
        inc i
    if dest == "" and sources.len > 0:
      dest = sources[^1]
      sources.setLen(sources.len - 1)
    if dest == "":
      continue
    if destIsDir or dest.endsWith("/") or dirExists(dest):
      for s in sources:
        result.add dest.strip(leading = false, trailing = true,
                              chars = {'/'}) & "/" & s.split('/')[^1]
    else:
      result.add dest

proc removeInstalled(name: string, paths: seq[string]) =
  for path in paths:
    if fileExists(path):
      run(name, "/", elevate("rm -f " & quoteShell(path)))
    elif dirExists(path):
      # rmdir solo borra vacíos: no se lleva nada ajeno.
      run(name, "/", elevate("rmdir " & quoteShell(path)))

proc removePackage*(pkg: string) =
  let recPath = findRecord(pkg)
  if recPath == "":
    echo pkg & ": no está instalado"
    return
  let rec = parseJson(readFile(recPath))
  let name = rec["name"].getStr()
  let dir = buildDirFor(name)
  if not dirExists(dir):
    echo "ERROR: no está la carpeta de compilación de " & name
    quit(1)
  echo name & ": desinstalando"
  let found = findUninstall(enterSource(dir))
  if found.kind != "":
    run(name, found.dir, elevate(found.command))
  else:
    # Capítulos cargo: el capítulo dice qué archivos puso.
    var chapter = ""
    for f in findPackage(name):
      if f.version == rec["version"].getStr():
        chapter = f.chapter
        break
    if chapter == "":
      echo "ERROR: no se encuentra el capítulo de " & name
      quit(1)
    var dests: seq[string]
    for s in installSteps(installSection(chapter)):
      if s.asRoot:
        dests.add installDests(s.code)
    if dests.len == 0:
      echo "ERROR: " & name & " no trae forma de desinstalación"
      quit(1)
    removeInstalled(name, dests)
  removeDir(dir)
  removeFile(recPath)
  echo name & ": desinstalado"
