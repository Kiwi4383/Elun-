{.push warning[Deprecated]: off.}
import std/md5
{.pop.}
import std/[httpclient, json, os, osproc, strutils, times, algorithm]
import common
import search
import update_books

type Step = tuple[asRoot: bool, code: string]

let stateDir* = getHomeDir() / ".local" / "share" / "elun"

proc safeName*(s: string): string =
  ## Nombres de capítulos y URLs llegan a rutas: sin esto un "../" escaparía
  ## de stateDir. Se guarda el nombre original en el JSON, esto es solo path.
  for c in s:
    if c.isAlphaNumeric or c in {'-', '_', '.'}:
      result.add c
    else:
      result.add '_'
  if result in ["", ".", ".."]:
    result = "_"

proc buildDirFor(name: string): string =
  stateDir / "build" / safeName(name)

proc recordPathFor(name: string): string =
  stateDir / "installed" / safeName(name) & ".json"

proc isRoot(): bool =
  try:
    return execCmdEx("id -u").output.strip() == "0"
  except CatchableError:
    return false

proc requireSudo(what: string) =
  if not isRoot() and findExe("sudo") == "":
    raise newException(IOError, "falta sudo, necesario para " & what)

proc requireInstallTools() =
  for tool in ["tar", "sh"]:
    if findExe(tool) == "":
      raise newException(IOError, "falta " & tool & ", necesario para instalar")
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
  ## "Download (HTTP)"/"Download:" y "Download MD5 sum" de la Package
  ## Information. GLFS/SLFS no publican MD5: ahí md5 viene vacío.
  var raw = listItemAfter(html, "Download (HTTP):").splitWhitespace()
  if raw.len == 0:
    raw = listItemAfter(html, "Download:").splitWhitespace()
  let sums = listItemAfter(html, "Download MD5 sum:").splitWhitespace()
  if raw.len == 0:
    return ("", "", false)
  for token in raw:
    if token.startsWith("http"):
      for s in sums:
        if s.len == 32 and s.allCharsInSet({'0' .. '9', 'a' .. 'f', 'A' .. 'F'}):
          return (token, s.toLowerAscii, true)
      return (token, "", true)
  return ("", "", false)

proc isRootTag*(tag: string): bool =
  ## Solo `class="root"` (palabra exacta, cualquier capitalización/comillas)
  ## manda a sudo. Un substring en otro atributo no alcanza.
  let low = tag.toLowerAscii
  var i = low.find("class")
  while i >= 0:
    # "class" dentro de otro nombre (data-class) no vale.
    if i > 0 and low[i - 1] in {'a'..'z', '0'..'9', '-', '_'}:
      i = low.find("class", i + 5)
      continue
    var j = i + 5
    while j < tag.len and tag[j] in {' ', '\t', '\n', '\r', '\f'}:
      inc j
    if j < tag.len and tag[j] == '=':
      inc j
      while j < tag.len and tag[j] in {' ', '\t', '\n', '\r', '\f'}:
        inc j
      if j < tag.len and tag[j] in {'"', '\''}:
        let q = tag[j]
        let k = tag.find(q, j + 1)
        if k > j:
          if "root" in tag[j + 1 ..< k].toLowerAscii.splitWhitespace():
            return true
          i = low.find("class", k + 1)
          continue
    i = low.find("class", j + 1)
  return false

const testParaMarks = ["test suite", "testsuite", "verification test",
  "regression test", "run the test", "run tests", "run the check"]

proc isTestPara*(para: string): bool =
  for m in testParaMarks:
    if m in para:
      return true
  return false

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
      if not isTestPara(lastPara):
        result.add (asRoot: isRootTag(tag),
                    code: unescapeEntities(stripTags(body[b + 1 ..< c])).strip())
      i = c + 6

proc findPrefix*(codes: seq[string]): string =
  for code in codes:
    for line in code.splitLines():
      let words = line.splitWhitespace()
      for i, w in words:
        let clean = w.strip(chars = {'\\', '"', '\''})
        if clean == "--prefix" and i + 1 < words.len:
          let v = words[i + 1].strip(chars = {'\\', '"', '\''})
          if v != "" and not v.startsWith("-"):
            return v
        elif clean.startsWith("--prefix="):
          let v = clean[len("--prefix=") .. ^1].strip(chars = {'\\', '"', '\''})
          if v != "":
            return v
        elif clean.startsWith("-DCMAKE_INSTALL_PREFIX="):
          let v = clean[len("-DCMAKE_INSTALL_PREFIX=") .. ^1].strip(
            chars = {'\\', '"', '\''})
          if v != "":
            return v
        elif clean == "-DCMAKE_INSTALL_PREFIX" and i + 1 < words.len:
          let v = words[i + 1].strip(chars = {'\\', '"', '\''})
          if v != "" and not v.startsWith("-"):
            return v
  return ""

proc stepScript*(code, stateFile: string): string =
  ## Cada <pre> corre en su propio sh: el archivo guarda dónde quedó el
  ## último para que el siguiente arranque ahí (`cd build` no se pierde).
  ## `set -e` sin `-u`: los capítulos LFS/MLFS usan variables como $LFS que
  ## acá no existen y con nounset el script se cortaría.
  ## El cwd restaurado se confina bajo el build dir (dirname del stateFile):
  ## un capítulo malicioso no puede llevar el próximo paso (root) afuera.
  result = "#!/bin/sh\nset -e\n"
  result.add "S=\"" & stateFile.replace("\\", "\\\\").replace("\"", "\\\"") &
    "\"\n"
  result.add "if [ -f \"$S\" ]; then D=\"$(cat \"$S\")\"; R=\"$(dirname \"$S\")\"; " &
    "case \"$D\" in \"$R\"|\"$R\"/*) cd \"$D\";; " &
    "*) echo \"cwd fuera del build, se ignora: $D\";; esac; fi\n"
  result.add code & "\n"
  result.add "pwd > " & quoteShell(stateFile) & "\n"
  result.add "[ -n \"${SUDO_USER:-}\" ] && chown \"$SUDO_USER\" " &
    quoteShell(stateFile) & " || true\n"

proc removeIfSymlink(path: string) =
  ## Si el tarball trae `.elun-step-N.sh`/`.elun-cwd` como symlink fuera del
  ## build, `writeFile`/`sh` lo seguirían. Se borra el enlace antes de usarlo.
  try:
    let kind = getFileInfo(path, followSymlink = false).kind
    if kind in [pcLinkToFile, pcLinkToDir]:
      if kind == pcLinkToDir:
        removeDir(path)
      else:
        removeFile(path)
  except OSError:
    discard

proc runStep*(pkg: string, step: Step, workDir: string, n: int,
              stateFile: string) =
  let script = workDir / ".elun-step-" & $n & ".sh"
  removeIfSymlink(script)
  removeIfSymlink(stateFile)
  writeFile(script, stepScript(step.code, stateFile))
  let who = if step.asRoot: "root" else: "user"
  echo "  [" & who & "] paso " & $n
  var command = "sh " & quoteShell(script)
  if step.asRoot and not isRoot():
    command = "sudo " & command
  let (output, code) = execCmdEx(command, workingDir = workDir)
  echo output
  if code != 0:
    # Fase 4: se aborta y queda el .log en la carpeta de compilación.
    let log = workDir / ".elun-failed.log"
    writeFile(log, "paquete: " & pkg & "\npaso: " & $n & " [" & who & "]\n" &
      "comando:\n" & step.code & "\nsalida:\n" & output)
    echo "ERROR: paso " & $n & " falló en " & pkg & " (log en " & log & ")"
    raise newException(IOError, "paso " & $n & " falló en " & pkg &
      " (log en " & log & ")")

proc checkMd5(path, expected: string) =
  let digest = ($toMD5(readFile(path))).toLowerAscii
  if digest != expected.toLowerAscii:
    raise newException(IOError, path & " no coincide con el MD5 del libro")

proc downloadSource(client: HttpClient, url, dest: string) =
  echo "Bajando fuente " & url
  writeFile(dest, fetch(client, url).body)

proc enterSource(workDir: string): string =
  ## El tarball suele traer un solo directorio: se entra en él. Si ese
  ## directorio es un symlink fuera del build, se aborta en vez de compilar
  ## afuera. Cualquier symlink de primer nivel que apunte fuera también
  ## aborta (los internos al árbol son normales en tarballs legítimos).
  var dirs: seq[string]
  for kind, path in walkDir(workDir):
    if kind == pcDir:
      dirs.add path
    elif kind in [pcLinkToFile, pcLinkToDir]:
      try:
        let raw = expandSymlink(path)
        let absT = normalizedPath(if raw.isAbsolute: raw
                                  else: path.parentDir / raw)
        let base = normalizedPath(workDir)
        if absT != base and not absT.startsWith(base & "/"):
          raise newException(IOError, "la fuente apunta fuera de " &
            workDir & ": " & path)
      except OSError as e:
        raise newException(IOError, "no se pudo revisar " & path &
          ": " & e.msg)
  if dirs.len == 1:
    try:
      if getFileInfo(dirs[0], followSymlink = false).kind == pcLinkToDir:
        raise newException(IOError, "la fuente apunta fuera de " & workDir)
    except OSError:
      raise newException(IOError, "no se pudo revisar " & dirs[0])
    return dirs[0]
  return workDir

proc memberOk(member: string): bool =
  let m = member.strip()
  if m == "" or m in [".", "./"]:
    return true
  if m.startsWith("/"):
    return false
  for part in m.split('/'):
    if part == "..":
      return false
  return true

proc checkTarballMembers(pkg, dest: string) =
  ## Zip-slip: el tarball viene de un mirror y `tar -xf`/`unzip` directo
  ## escribiría miembros `../`/absolutos fuera del build. Se lista primero.
  if dest.endsWith(".zip"):
    let listOut = execCmdEx("unzip -Z1 " & quoteShell(dest),
                            workingDir = dest.parentDir)
    if listOut.exitCode != 0:
      return # unzip viejo sin -Z1: sin chequeo, como antes
    for member in listOut.output.splitLines():
      if not memberOk(member):
        raise newException(IOError, pkg & ": el archivo trae miembro fuera" &
          " del build (" & member.strip() & "), no se extrae")
  else:
    let listOut = execCmdEx("tar -tf " & quoteShell(dest),
                            workingDir = dest.parentDir)
    if listOut.exitCode != 0:
      raise newException(IOError, pkg & ": no se pudo listar " & dest)
    for member in listOut.output.splitLines():
      if not memberOk(member):
        raise newException(IOError, pkg & ": el archivo trae miembro fuera" &
          " del build (" & member.strip() & "), no se extrae")
    let verbOut = execCmdEx("tar -tvf " & quoteShell(dest),
                            workingDir = dest.parentDir)
    if verbOut.exitCode == 0:
      for line in verbOut.output.splitLines():
        let arrow = line.find(" -> ")
        if arrow >= 0:
          let target = line[arrow + 4 .. ^1].strip()
          if target.startsWith("/") or not memberOk(target):
            raise newException(IOError, pkg & ": el archivo trae enlace" &
              " fuera del build (" & target & "), no se extrae")

proc unpack(pkg, dest: string): string =
  checkTarballMembers(pkg, dest)
  if dest.endsWith(".zip"):
    if findExe("unzip") == "":
      raise newException(IOError, "falta unzip, necesario para " & dest)
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
  # Sin duplicados por mayúsculas ("Foo" vs "foo"): queda el recién escrito.
  for path in walkFiles(stateDir / "installed" / "*.json"):
    if path != recordPathFor(f.name) and
        path.splitFile().name.toLowerAscii == safeName(f.name).toLowerAscii:
      try:
        removeFile(path)
      except OSError:
        discard

proc formatDur*(secs: int64): string =
  let h = secs div 3600
  let m = (secs mod 3600) div 60
  let s = secs mod 60
  if h > 0:
    return $h & "h" & $m & "m" & $s & "s"
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

proc orphansOf*(pkgs: seq[tuple[name: string, deps: seq[string]]]): seq[string] =
  ## Huérfano = instalado que ningún otro instalado lista como dependencia.
  ## Los nombres se comparan sin versión y sin mayúsculas ("libpsl-0.23.3" vale
  ## por "libpsl"). Sin registro de motivo de instalación, una hoja instalada
  ## a mano también sale: eso lo resuelve la fase 4 con resolución de
  ## dependencias.
  var needed: seq[string]
  for p in pkgs:
    for d in p.deps:
      let n = splitNameVersion(d).name.toLowerAscii
      if n != "" and n notin needed:
        needed.add n
  for p in pkgs:
    if p.name.toLowerAscii notin needed:
      result.add p.name

proc listOrphans*() =
  let recs = readRecords(stateDir / "installed")
  if recs.len == 0:
    echo "no hay paquetes instalados"
    return
  var pkgs: seq[tuple[name: string, deps: seq[string]]]
  for r in recs:
    let name = recName(r)
    var deps: seq[string]
    # Solo lectura: sin red ni re-baja de libros. Si la versión instalada ya
    # no está en los libros, valen las deps de cualquier versión homónima
    # antes que declarar todo huérfano.
    var sameName: seq[Found] = @[]
    for f in findPackageLocal(name):
      if f.name.toLowerAscii == name.toLowerAscii:
        sameName.add f
    for f in sameName:
      if f.version == r.getOrDefault("version").getStr(""):
        deps.add f.deps.build
        deps.add f.deps.runtime
        break
    if deps.len == 0 and sameName.len > 0:
      deps.add sameName[0].deps.build
      deps.add sameName[0].deps.runtime
    pkgs.add (name, deps)
  let orphans = orphansOf(pkgs)
  if orphans.len == 0:
    echo "no hay huérfanos"
  else:
    for o in orphans:
      echo o

proc findRecord*(name: string): string =
  ## Ruta del registro instalado, sin distinguir mayúsculas.
  if not dirExists(stateDir / "installed"):
    return ""
  for path in walkFiles(stateDir / "installed" / "*.json"):
    if path.splitFile().name.toLowerAscii == safeName(name).toLowerAscii:
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
  # Build limpio: la fuente vieja, `.elun-cwd` y `.elun-step-*.sh` viejos
  # hacían que el update compilara en el directorio equivocado. "Sin borrar
  # la carpeta" (Elun.md) es la instalada, no la de compilación.
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  let tarball = dir / safeName(url.split('/')[^1])
  let client = newHttpClient(userAgent = "elun")
  # Sin MD5 no hay cómo verificar un tarball viejo: se baja de nuevo.
  if not fileExists(tarball) or md5 == "":
    downloadSource(client, url, tarball)
  if md5 != "":
    checkMd5(tarball, md5)
  else:
    echo "  aviso: el libro no publica MD5, solo protege el TLS"
  client.close()
  let srcDir = unpack(f.name, tarball)
  let steps = installSteps(installSection(f.chapter))
  if steps.len == 0:
    raise newException(IOError,
      "el capítulo no trae comandos de instalación")
  var codes: seq[string]
  for i, step in steps:
    runStep(f.name, step, srcDir, i + 1, dir / ".elun-cwd")
    if not step.asRoot:
      codes.add step.code
  let secs = (now() - t0).inSeconds
  writeRecord(f, url, md5, findPrefix(codes), secs)
  return secs

proc buildFromFound(f: Found, action: string) =
  let src = packageSource(f.chapter)
  if not src.ok:
    raise newException(IOError, "el capítulo no trae descarga")
  let prev = recordDurations()
  let secs = buildAndRecord(f, src.url, src.md5)
  echo action & ": " & f.name & "-" & f.version & " (tardó " &
    formatDur(secs) & ", promedio " & formatDur(average(prev & @[secs])) &
    ")"

proc installPackage*(pkg: string): bool =
  requireInstallTools()
  let found = findPackage(pkg)
  if found.len == 0:
    return false
  # La búsqueda ya viene en orden developer primero: se instala la primera.
  let f = found[0]
  printFound(@[f])
  echo f.name & "-" & f.version & " de " & f.book & ": instalando"
  buildFromFound(f, "instalado")
  return true

proc updatePackage*(pkg: string): bool =
  requireInstallTools()
  let recPath = findRecord(pkg)
  if recPath == "":
    echo pkg & ": no está instalado, usá `elun install` primero"
    return false
  var rec: JsonNode
  try:
    rec = parseJson(readFile(recPath))
  except CatchableError:
    echo "ERROR: registro corrupto: " & recPath
    return false
  if not rec.hasKey("name") or not rec.hasKey("version"):
    echo "ERROR: registro corrupto: " & recPath
    return false
  let found = findPackage(rec["name"].getStr())
  if found.len == 0:
    return false
  let f = found[0]
  if f.version == rec["version"].getStr():
    echo f.name & " ya está en la última versión (" & f.version & ")"
    return true
  # Se compila encima sin borrar la carpeta, como pide el doc.
  echo f.name & " " & rec["version"].getStr() & " -> " & f.version &
    " de " & f.book & ": actualizando"
  buildFromFound(f, "actualizado")
  return true

proc elevate(command: string): string =
  ## sudo salvo que ya se sea root.
  if isRoot():
    return command
  requireSudo("desinstalar")
  return "sudo " & command

proc hasTarget(dir, tool, makefile, target: string): bool =
  ## `make -n`/`ninja -n` solo preguntan... salvo que el Makefile use
  ## `$(shell ...)`: make lo evalúa al parsear. En ese caso no se pregunta.
  if not fileExists(dir / makefile):
    return false
  try:
    if "$(shell" in readFile(dir / makefile):
      return false
  except CatchableError:
    return false
  try:
    return execCmdEx(quoteShell(tool) & " -n " & quoteShell(target),
                     workingDir = dir).exitCode == 0
  except CatchableError:
    return false

proc findUninstall*(srcDir: string): tuple[kind, dir, command: string] =
  ## Cómo desinstalar: regla del Makefile, manifiesto de cmake o nada. El
  ## manifiesto cubre a cmake, que genera Makefiles con install pero sin
  ## uninstall. En command va la orden o la ruta del manifiesto.
  for sub in ["", "build"]:
    let dir = if sub == "": srcDir else: srcDir / sub
    if hasTarget(dir, "make", "Makefile", "uninstall"):
      return ("rule", dir, "make uninstall")
    if hasTarget(dir, "ninja", "build.ninja", "uninstall"):
      return ("rule", dir, "ninja uninstall")
  for sub in ["", "build"]:
    let dir = if sub == "": srcDir else: srcDir / sub
    if fileExists(dir / "install_manifest.txt"):
      return ("manifest", dir, dir / "install_manifest.txt")
  return ("", "", "")

proc underPrefix*(p, prefix: string): bool =
  p == prefix or p.startsWith(prefix & "/")

proc filterByPrefix*(paths: seq[string], prefix: string): seq[string] =
  ## Solo entra lo instalado bajo el prefijo registrado. Sin prefijo no se
  ## puede saber: entra todo como antes.
  for p in paths:
    if prefix == "" or underPrefix(p, prefix):
      result.add p

proc cmakePrefix*(dir: string): string =
  ## CMAKE_INSTALL_PREFIX del CMakeCache, para confinar el manifiesto cuando
  ## el registro no trae prefijo.
  for sub in ["", "build"]:
    let cache = (if sub == "": dir else: dir / sub) / "CMakeCache.txt"
    if not fileExists(cache):
      continue
    for line in lines(cache):
      if line.startsWith("CMAKE_INSTALL_PREFIX:"):
        let parts = line.split('=', 1)
        if parts.len == 2 and parts[1].strip() != "":
          return parts[1].strip()
  return ""

proc uninstallManifest*(name, manifest, prefix: string, srcDir: string) =
  var effective = prefix
  if effective == "":
    effective = cmakePrefix(srcDir)
  if effective == "":
    echo "ERROR: " & name &
      ": sin prefijo no se toca el manifiesto (negado por seguridad)"
    return
  var files: seq[string]
  var dirs: seq[string]
  var outside = 0
  for line in lines(manifest):
    let p = line.strip()
    if p == "":
      continue
    if effective != "" and not underPrefix(p, effective):
      echo "  salto fuera de prefijo: " & p
      inc outside
      continue
    if fileExists(p):
      files.add p
    elif dirExists(p):
      dirs.add p
  if files.len > 0:
    # -d '\n': las rutas con espacios no se parten.
    let list = manifest & ".elun-filtered"
    writeFile(list, files.join("\n") & "\n")
    run(name, manifest.parentDir,
        elevate("xargs -d '\\n' rm -f < " & quoteShell(list)))
    removeFile(list)
  for d in dirs:
    run(name, manifest.parentDir, elevate("rmdir " & quoteShell(d)))

proc installDests*(code: string): seq[string] =
  ## Destinos concretos de los `install` del capítulo (capítulos cargo). Las
  ## banderas se saltan (-m/-o/-g comen el siguiente token) y -t dir invierte.
  ## Solo valen rutas absolutas: una relativa se chequea en un cwd y se
  ## borraría en otro. `cargo install` no da destinos fiables: se salta.
  for rawLine in code.splitLines():
    for chunk in rawLine.replace("&&", ";").replace("||", ";").split(';'):
      var line = chunk.strip()
      while line.startsWith("sudo ") or line.startsWith("sudo\t"):
        line = line[5 .. ^1].strip()
      var tokens = line.splitWhitespace()
      if tokens.len == 0:
        continue
      if tokens[0] == "cargo":
        continue
      if tokens[0].split('/')[^1] != "install":
        continue
      if tokens.len < 3:
        continue
      var sources: seq[string]
      var dest = ""
      var destIsDir = false
      var i = 1
      while i < tokens.len:
        let t = tokens[i].strip(chars = {'\'', '"'})
        if t == "-t" or t == "--target-directory":
          if i + 1 < tokens.len:
            dest = tokens[i + 1].strip(chars = {'\'', '"'})
            destIsDir = true
          inc i, 2
        elif t.startsWith("--target-directory="):
          dest = t[len("--target-directory=") .. ^1].strip(
            chars = {'\'', '"'})
          destIsDir = true
          inc i
        elif t.len > 0 and t[0] == '-':
          inc i
          if t in ["-m", "-o", "-g", "--owner", "--group", "--mode"] and
              i < tokens.len:
            inc i
        else:
          sources.add t
          inc i
      if dest == "" and sources.len > 0:
        dest = sources[^1]
        sources.setLen(sources.len - 1)
      if dest == "" or not dest.startsWith("/"):
        continue
      if destIsDir or dest.endsWith("/") or dirExists(dest):
        for s in sources:
          result.add dest.strip(leading = false, trailing = true,
                                chars = {'/'}) & "/" & s.split('/')[^1]
      else:
        result.add dest

proc removeInstalled(name: string, paths: seq[string]) =
  for path in paths:
    if not path.startsWith("/"):
      echo "  salto relativo (inseguro): " & path
      continue
    if fileExists(path):
      run(name, "/", elevate("rm -f " & quoteShell(path)))
    elif dirExists(path):
      # rmdir solo borra vacíos: no se lleva nada ajeno.
      run(name, "/", elevate("rmdir " & quoteShell(path)))

proc removePackage*(pkg: string): bool =
  let recPath = findRecord(pkg)
  if recPath == "":
    echo pkg & ": no está instalado"
    return false
  var rec: JsonNode
  try:
    rec = parseJson(readFile(recPath))
  except CatchableError:
    echo "ERROR: registro corrupto: " & recPath
    return false
  let name = rec.getOrDefault("name").getStr("")
  if name == "":
    echo "ERROR: registro corrupto: " & recPath
    return false
  let dir = buildDirFor(name)
  if not dirExists(dir):
    echo "ERROR: no está la carpeta de compilación de " & name
    return false
  echo name & ": desinstalando"
  let found = findUninstall(enterSource(dir))
  if found.kind == "rule":
    run(name, found.dir, elevate(found.command))
  elif found.kind == "manifest":
    uninstallManifest(name, found.command, rec.getOrDefault("prefix").getStr(""),
                      enterSource(dir))
  else:
    # Capítulos cargo: el capítulo dice qué archivos puso.
    var chapter = ""
    for f in findPackage(name):
      if f.version == rec.getOrDefault("version").getStr(""):
        chapter = f.chapter
        break
    if chapter == "":
      echo "ERROR: no se encuentra el capítulo de " & name
      return false
    var dests: seq[string]
    for s in installSteps(installSection(chapter)):
      if s.asRoot:
        dests.add installDests(s.code)
    let cargoPrefix = rec.getOrDefault("prefix").getStr("")
    if cargoPrefix == "":
      echo "ERROR: " & name &
        ": sin prefijo no se desinstala por rutas del capítulo (negado por seguridad)"
      return false
    dests = filterByPrefix(dests, cargoPrefix)
    if dests.len == 0:
      echo "ERROR: " & name & " no trae forma de desinstalación"
      return false
    removeInstalled(name, dests)
  try:
    removeDir(dir)
    removeFile(recPath)
  except OSError:
    # Pasos root dejan archivos de root: reintentar borrado con sudo.
    try:
      run(name, "/", elevate("rm -rf " & quoteShell(dir)))
      removeFile(recPath)
    except CatchableError as e:
      echo "ERROR: no se pudo borrar estado de " & name & ": " & e.msg
      echo "  (restos de root: reintentá con sudo)"
      return false
  echo name & ": desinstalado"
  return true
