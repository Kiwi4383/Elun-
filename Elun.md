> Provisional: esta es la idea de cómo se va a instalar todo, no la implementación final. Lo que se vea después, se cambia.

### Fase 1 ###

Elun baja y mantiene al día los libros.

1. Fuentes (ver `~/Descargas/message.txt`). Son seis libros, porque la fase 2
   necesita las dos ramas de cada uno:
   - LFS development: el índice de `https://www.linuxfromscratch.org/lfs/downloads/development/` (NOCHUNKS, porque LFS no publica chunks en development).
   - LFS stable/systemd: el índice de `https://www.linuxfromscratch.org/lfs/downloads/stable-systemd/`.
   - BLFS development/systemd: `https://www.linuxfromscratch.org/blfs/view/systemd/`. No existe como archivo único: solo se sirve partido en capítulos, así que Elun baja la portada y después los 747 archivos que ella enlaza.
   - BLFS stable/systemd: el índice de `https://www.linuxfromscratch.org/blfs/downloads/stable-systemd/`.
   - MLFS: `git clone --branch multilib https://git.linuxfromscratch.org/lfs.git` + `make REV=systemd`.
   - GLFS: `git clone https://github.com/glfs-book/glfs.git` + `make`.
   - SLFS: `git clone https://github.com/glfs-book/slfs.git` + `make`.
2. Destino: `~/LFS-BOOKS-DEV`, un subdirectorio por libro. Mantenerlos actualizados es volver a correr lo mismo: `curl` para LFS y BLFS, `git pull` para MLFS, GLFS y SLFS, y `make` para los que se renderizan. A `make` hay que pasarle `BASEDIR` por línea de comandos, porque los Makefiles por defecto escriben en `~/public_html/<libro>`, que queda fuera de `~/LFS-BOOKS-DEV`. Prerrequisitos del sistema para el paso `make`: `git`, `make`, `xsltproc`, `tidy`, `docbook-xsl` y `docbook-xml` (los XSL de los libros importan DocBook XSL por catálogo local, con `--nonet`).
3. Para saber cuál es la última versión, Elun mira la página de descargas. No lleva la versión pegada en la URL.
4. Todo lo que baja se comprueba con SHA256, así no se come un archivo cortado o cambiado. El sitio no publica un digest de los libros (su `md5sums` solo cubre los fuentes de los paquetes), así que el hash es una huella local: Elun guarda el de la descarga anterior en un manifiesto por libro y avisa cuando el archivo que baja ahora ya no es el mismo. Contra un archivo cortado está el chequeo de `content-length`.
5. Elun saca los comandos del HTML ya renderizado del libro, no del XML original con el que se arma.
6. Para descargar cualquier mierda obligatoriamente TIENE que basarse en los libros.

### Fase 2 ###

Elun elige de qué rama saca cada paquete.

1. Mantiene las ramas estable y developer de LFS, MLFS, BLFS, SLFS y GLFS. Todas son variaciones oficiales mantenidas por el proyecto LFS. MLFS, GLFS y SLFS no tienen rama estable publicada: cuentan como developer.
2. Prioriza la rama developer sobre la estable. La estable sigue ahí y se usa cuando el paquete no está en developer.
3. Orden de búsqueda de un paquete: primero developer, después estable. Si no está en ninguna de las dos, Elun revisa si hay una versión nueva de los libros; si la hay, la descarga y repite la búsqueda. Si aun así no aparece, o no hay libros nuevos, salta un aviso por log de que ese paquete no existe. Libro nuevo se detecta sin bajar todo: nombre del nochunks en el índice (`.elun-source`), hash de la portada del BLFS development y `git ls-remote` contra el checkout para MLFS, GLFS y SLFS.
4. No resuelve dependencias, pero sí avisa por log de cuáles necesita el programa. La lista sale del propio capítulo del paquete: qué hace falta para compilarlo y qué hace falta para que funcione. Si un paquete no trae esa lista, Elun avisa que desconoce qué dependencias necesita. Mapeo: Required y Recommended van a compilar, lo marcado como runtime va a funcionar, el resto es opcional. En LFS/MLFS la lista sale del apéndice C del mismo libro.

### Fase 3 ###

Elun instala.

1. Se usa la información que dan los propios libros para iniciar la instalación de un paquete: dónde crear las carpetas y qué compilador necesita.
2. Elun ejecuta los comandos del libro. La idea es un mini Portage: pedís el paquete y Elun hace la compilación. Vale todo libro, incluido LFS/MLFS sobre el host.
3. Se usa la configuración estándar de cada libro. Elun no inventa rutas: usa las que el propio libro define. Los comandos marcados para root (`<pre class="root">`) se corren con sudo; el resto como el usuario actual. Las test suites no se corren en la instalación.
4. Las carpetas creadas para los paquetes NO llevan su número de versión, solamente el nombre del programa: "Discord", no "Discord.198.2.1". Internamente Elun sí guarda la versión, y el programa la muestra con `--version`.
5. Al actualizar, Elun compila encima de lo que ya está instalado, sin borrar la carpeta. Es decisión de quien pidió el proyecto.
6. Cada instalación deja registro (nombre, versión, libro, fecha, fuente, MD5 y prefijo) para que update, remove y orphans tengan de dónde leer después.

### Fase 4 ###

Propuesta, sin pulir. Queda decidir:

1. Cuando un paquete falla al compilar, Elun aborta y deja un `.elun-failed.log` en la carpeta de compilación con el paso, el comando y la salida. No reintenta solo.
2. Que Elun resuelva solo las dependencias, en vez de solo avisarlas.
3. El enrutador de decisiones (el "router", de decisiones y no de red) para enseñarle al gestor a resolver problemas menores de compilación durante la instalación/actualización. Sigue siendo una idea sin decidir.

### Comandos ###

Todo en inglés.

- `elun install <paquete>`
- `elun update <paquete>` — actualiza el paquete.
- `elun update-books` — baja y actualiza los libros.
- `elun remove <paquete>` — desinstala el paquete (fase 3). Usa la regla
  `uninstall` del Makefile si existe (verificado con `make -n`, sin ejecutar),
  si no el `install_manifest.txt` de cmake, si no los destinos de los comandos
  `install` del propio capítulo (capítulos cargo).
- `elun orphans` — lista los instalados que ningún otro instalado necesita.
- `elun list` — paquetes instalados con versión, libro y tiempo.
- `elun search <paquete>` — búsqueda de solo lectura, sin instalar.

### Calidad de vida ###

1. Una función para promediar la cantidad de tiempo que tarda en instalar o actualizar cada paquete.

### Stack ###

- Nim.

Una fase se da por terminada cuando el gestor lo dice. Como criterio básico: que las funciones existan y hagan lo que dicen.
