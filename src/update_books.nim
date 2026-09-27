import std/[algorithm, httpclient, os, osproc, sequtils, strutils, tables]
import libsha / sha256
import common

const lfsDownloads* = "https://www.linuxfromscratch.org/lfs/downloads/"
const blfsDownloads* = "https://www.linuxfromscratch.org/blfs/downloads/"

# BLFS no publica el development como un archivo único: solo lo sirve partido en
# capítulos, así que hay que bajar la portada y después todo lo que ella enlaza.
const blfsDevelopment* = "https://www.linuxfromscratch.org/blfs/view/systemd/"

# MLFS, GLFS y SLFS no se publican como un HTML listo: sus fuentes viven en git y
# make renderiza el libro.
const mlfsRepo* = "https://git.linuxfromscratch.org/lfs.git"
const glfsRepo* = "https://github.com/glfs-book/glfs.git"
const slfsRepo* = "https://github.com/glfs-book/slfs.git"

# (libro, nombre local, índice): los libros de un solo archivo.
const indexBooks* = [
  ("LFS", "LFS-development.html", lfsDownloads & "development/"),
  ("LFS", "LFS-stable-systemd.html", lfsDownloads & "stable-systemd/"),
  ("BLFS", "BLFS-stable-systemd.html", blfsDownloads & "stable-systemd/")
]

# (libro, repo, rama, targets, rev): los libros que se renderizan con make.
const renderedBooks* = [
  ("MLFS", mlfsRepo, "multilib", "book nochunks", "REV=systemd"),
  ("GLFS", glfsRepo, "", "html", ""),
  ("SLFS", slfsRepo, "", "html", "")
]

proc currentBook*(client: HttpClient, dirUrl: string): string =
  ## Devuelve el nombre del HTML de un solo archivo que el sitio tiene ahora.
  ## El índice ya dice cuál está vigente, así que no hay que comparar versiones.
  ## LFS lo escribe NOCHUNKS y BLFS nochunks, por eso se compara en minúscula.
  for href in hrefsIn(fetch(client, dirUrl).body):
    if href.toLowerAscii.endsWith("nochunks.html"):
      return href
  echo "ERROR: no hay libro de un solo archivo en " & dirUrl
  quit(1)

proc loadHashes*(bookDir: string): Table[string, string] =
  ## Ruta relativa dentro del libro -> sha256 de la descarga anterior.
  let manifest = bookDir / ".elun-hashes"
  if not fileExists(manifest):
    return
  for line in lines(manifest):
    let parts = line.splitWhitespace()
    if parts.len == 2:
      result[parts[1]] = parts[0]

proc saveHashes*(bookDir: string, hashes: Table[string, string]) =
  var text = ""
  var names = toSeq(hashes.keys)
  names.sort()
  for name in names:
    text.add hashes[name] & "  " & name & "\n"
  writeFile(bookDir / ".elun-hashes", text)

proc readSources*(bookDir: string): Table[string, string] =
  ## Índice -> nombre del libro vigente cuando se bajó.
  let path = bookDir / ".elun-source"
  if not fileExists(path):
    return
  for line in lines(path):
    let parts = line.splitWhitespace()
    if parts.len == 2:
      result[parts[0]] = parts[1]

proc writeSources*(bookDir: string, sources: Table[string, string]) =
  var text = ""
  var urls = toSeq(sources.keys)
  urls.sort()
  for url in urls:
    text.add url & " " & sources[url] & "\n"
  writeFile(bookDir / ".elun-source", text)

proc recordHash*(hashes: var Table[string, string], name: string,
                 content: string): bool =
  ## El sitio no publica el sha256 de los libros (su md5sums solo cubre los
  ## fuentes de los paquetes), así que el hash sirve de huella local: Elun
  ## guarda el de la descarga anterior y avisa cuando el archivo que baja ahora
  ## ya no es el mismo. Devuelve true cuando el archivo es nuevo o cambió, para
  ## no reescribir lo que ya estaba igual.
  let digest = sha256hexdigest(content)
  let old = hashes.getOrDefault(name, "")
  if old != "" and old != digest:
    echo "  aviso: " & name & " no es el mismo archivo que en la descarga anterior"
  hashes[name] = digest
  return old != digest

proc downloadBook*(client: HttpClient, bookDir: string,
                   hashes: var Table[string, string], name: string, url: string) =
  echo "Bajando " & name
  let response = fetch(client, url)
  if recordHash(hashes, name, response.body):
    let path = bookDir / name
    createDir(path.parentDir)
    writeFile(path, response.body)

proc fetchIndexBook(client: HttpClient, book, name, indexUrl,
                      current: string) =
  let bookDir = booksDir / book
  createDir(bookDir)
  var hashes = loadHashes(bookDir)
  downloadBook(client, bookDir, hashes, name, indexUrl & current)
  saveHashes(bookDir, hashes)
  var sources = readSources(bookDir)
  sources[indexUrl] = current
  writeSources(bookDir, sources)

proc updateDownloadBooks(client: HttpClient) =
  ## Los libros que el proyecto LFS publica como un HTML de un solo archivo.
  ## El nombre vigente del índice se guarda en .elun-source: así la búsqueda
  ## sabe si salió una versión nueva sin tener que bajar el libro.
  for (book, name, indexUrl) in indexBooks:
    fetchIndexBook(client, book, name, indexUrl, currentBook(client, indexUrl))

proc updateBlfsDevelopment*(client: HttpClient) =
  ## La portada del development enlaza cada capítulo con una ruta relativa, así
  ## que se bajan todos y se guardan con esa misma estructura.
  let bookDir = booksDir / "BLFS"
  let pagesDir = "BLFS-development-systemd"
  createDir(bookDir / pagesDir)
  var hashes = loadHashes(bookDir)

  let index = fetch(client, blfsDevelopment).body
  if recordHash(hashes, pagesDir & "/index.html", index):
    writeFile(bookDir / pagesDir / "index.html", index)

  var pages: seq[string]
  for href in hrefsIn(index):
    # La portada enlaza preface/preface.html dos veces, así que se descarta lo
    # repetido para no bajarlo de nuevo.
    if (href.endsWith(".html") or href.endsWith(".css")) and
        not href.startsWith("/") and href notin pages:
      pages.add href
  echo "BLFS development: " & $pages.len & " archivos"

  for i, page in pages:
    let content = fetch(client, blfsDevelopment & page).body
    if recordHash(hashes, pagesDir & "/" & page, content):
      let path = bookDir / pagesDir / page
      createDir(path.parentDir)
      writeFile(path, content)
    if (i + 1) mod 50 == 0:
      echo "  " & $(i + 1) & "/" & $pages.len
  saveHashes(bookDir, hashes)

proc run(book: string, dir: string, command: string) =
  echo "  " & command
  let (output, code) = execCmdEx(command, workingDir = dir)
  if code != 0:
    echo output
    echo "ERROR: " & command & " falló en " & book
    quit(1)

proc syncRenderedBook*(book, repo, branch, targets, rev: string) =
  echo book
  let checkout = booksDir / book
  createDir(checkout)

  if dirExists(checkout / ".git"):
    run(book, checkout, "git fetch --quiet origin")
    if branch != "":
      run(book, checkout, "git checkout --quiet " & branch)
    run(book, checkout, "git pull --ff-only --quiet")
  else:
    var clone = "git clone --quiet"
    if branch != "":
      clone.add " --branch " & branch
    clone.add " " & repo & " " & quoteShell(checkout)
    run(book, booksDir, clone)

  # El html lo escribe xsltproc antes de que el Makefile corra un solo mkdir,
  # así que el directorio tiene que existir de antemano.
  let renderDir = checkout / "html"
  createDir(renderDir)
  run(book, checkout, "make --no-print-directory " & targets &
      " BASEDIR=" & quoteShell(renderDir) & " " & rev)

proc syncIndexBookIfChanged*(client: HttpClient, book, name,
                             indexUrl: string): bool =
  ## Baja el libro solo si el índice nombra otro archivo que el registrado.
  let current = currentBook(client, indexUrl)
  if readSources(booksDir / book).getOrDefault(indexUrl, "") == current:
    return false
  fetchIndexBook(client, book, name, indexUrl, current)
  return true

proc syncBlfsDevIfChanged*(client: HttpClient): bool =
  ## La portada cambia con cada versión del development: si su hash ya no es
  ## el del manifiesto, hay libro nuevo y se re-bajan las páginas.
  let bookDir = booksDir / "BLFS"
  let index = fetch(client, blfsDevelopment).body
  let old = loadHashes(bookDir).getOrDefault(
    "BLFS-development-systemd/index.html", "")
  if old == sha256hexdigest(index):
    return false
  updateBlfsDevelopment(client)
  return true

proc updateRenderedBooks() =
  ## BASEDIR se pasa por línea de comandos porque los Makefiles por defecto
  ## escriben en $(HOME)/public_html/<libro>, que queda fuera de booksDir.
  ## Los targets son los que arman el HTML: el de pdf de MLFS pide fop, que no
  ## hace falta para leer el libro.
  for (book, repo, branch, targets, rev) in renderedBooks:
    syncRenderedBook(book, repo, branch, targets, rev)

proc migrateFlatLayout() =
  ## La primera versión de Elun dejaba los HTML sueltos en la raíz de booksDir.
  ## Se mueven a su subdirectorio para que la raíz quede limpia. Los .md5 se
  ## borran porque el manifiesto nuevo los reemplaza.
  let moves = [
    ("LFS-development.html", "LFS"),
    ("LFS-stable-systemd.html", "LFS"),
    ("BLFS-stable-systemd.html", "BLFS")
  ]
  for (name, book) in moves:
    let oldPath = booksDir / name
    if not fileExists(oldPath):
      continue
    let newPath = booksDir / book / name
    if fileExists(newPath):
      removeFile(oldPath)
    else:
      createDir(booksDir / book)
      moveFile(oldPath, newPath)
    echo "migrado: " & name & " -> " & book
  for oldHashes in walkFiles(booksDir / "*.md5"):
    removeFile(oldHashes)

proc requireTools(tools: openArray[string]) =
  for tool in tools:
    if findExe(tool) == "":
      echo "ERROR: falta " & tool &
           ", que necesitan los Makefile de MLFS, GLFS y SLFS"
      quit(1)

proc updateBooks*() =
  createDir(booksDir)
  migrateFlatLayout()
  requireTools(["git", "make", "xsltproc", "tidy"])

  let client = newHttpClient(userAgent = "elun")
  updateDownloadBooks(client)
  updateBlfsDevelopment(client)
  client.close()

  updateRenderedBooks()
  echo "Los libros quedaron en " & booksDir
