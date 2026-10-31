# rayblob

Un almacén de objetos compatible con S3, escrito en [raylang](https://github.com/ray-language/raylang).
Buckets, objetos, subidas multipart y URLs prefirmadas, con la firma SigV4 de AWS. Los clientes de S3
de siempre (`aws`, los SDK, `curl` con una URL prefirmada) hablan con él sin cambiar nada más que el
endpoint.

```
$ rayblob keygen admin >> rayblob.toml      # sobre una copia de rayblob.example.toml
$ rayblob serve
rayblob 0.1.0: http://127.0.0.1:9300, data in data, region us-east-1, 1 key(s), objects up to 64 MiB per request

$ export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
$ aws --endpoint-url http://127.0.0.1:9300 s3 mb s3://fotos
$ aws --endpoint-url http://127.0.0.1:9300 s3 cp video.mp4 s3://fotos/
$ rayblob presign --method PUT --expires 600 fotos/subida.jpg      # una URL de subida para quien no tiene claves
http://127.0.0.1:9300/fotos/subida.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&…
```

```
rayblob serve [--config rayblob.toml]
rayblob presign [--config rayblob.toml] [--key NAME] [--method GET|PUT] [--expires SECONDS] [--host HOST:PORT] BUCKET/KEY
rayblob keygen NAME
```

## Estado

| Qué | Estado |
|---|---|
| Buckets: crear, borrar (solo vacíos), HEAD, listar, `?location`, `?versioning` | ✅ |
| Objetos: PUT, GET, HEAD, DELETE, metadatos `x-amz-meta-*`, `Content-Type`, `Content-MD5` | ✅ |
| GET con `Range`, `If-Match`, `If-None-Match`, `If-Range` y `response-content-*` | ✅ |
| ListObjects v1 y v2: `prefix`, `delimiter`, páginas, `continuation-token`, `start-after`, `encoding-type=url` | ✅ |
| CopyObject (`x-amz-copy-source`, `COPY`/`REPLACE`) y DeleteObjects (el `rm --recursive`) | ✅ |
| Multipart: iniciar, subir partes, ListParts, completar (ETag `md5-N`), abortar | ✅ |
| SigV4 por cabecera, cuerpo firmado o `UNSIGNED-PAYLOAD`, `aws-chunked` (firmado chunk a chunk o con trailer) | ✅ |
| URLs prefirmadas (GET y PUT), `rayblob presign` y las de `aws s3 presign` | ✅ |
| Permisos por clave (buckets y escritura) y por objeto (`private` / `public-read`, `?acl`) | ✅ |
| Reinicio sin pérdida; barrido de blobs huérfanos al arrancar | ✅ |
| ListMultipartUploads, versiones, ciclo de vida, políticas de bucket, URLs virtual-host | ➖ v2 |
| Subidas por streaming sin tope por petición | ❌ el servidor web recibe el cuerpo entero (#284) |

Pruebas: 14 tests (`make test`, `make test-native`), en VM y nativo; y `make interop`, que lanza el
binario contra el `aws` CLI de verdad (24 comprobaciones, entre ellas una subida multipart de 200 MB
que se descarga y se compara byte a byte).

## Cómo

```
src/main.ray     la línea de órdenes (serve, presign, keygen)
src/config.ray   rayblob.toml: dirección, datos, región, claves
src/server.ray   net/webserver + la fibra del índice
src/s3.ray       la API: rutas, autenticación, permisos, XML, multipart, copia
src/index.ray    el índice en SQLite, dueño de una sola fibra
src/blobs.ray    los bytes en disco: escribir, sincronizar, renombrar, unir partes
```

La firma SigV4 del lado servidor (verificar, prefirmar, chunks firmados) es `net/sigv4`, desde
net 0.14.0.

- **Los bytes y el índice van por separado.** El handler de cada conexión escribe el cuerpo en
  `data/tmp/`, hace `fsync` (`fs.sync_data`) y lo renombra a `data/blobs/<xx>/<id>`; solo entonces
  pide a la fibra del índice que el objeto apunte a ese blob. El índice nunca nombra un archivo a
  medio escribir. Si el proceso muere entre el rename y el commit, al arrancar se borran los blobs
  que el índice no nombra, y también lo que quedó en `tmp/`.
- **Los blobs no cambian nunca.** Sobrescribir crea uno nuevo; el índice devuelve el que dejó de
  usarse y el handler lo borra. Dos PUT a la misma clave a la vez no se pisan: gana el último commit
  y el otro blob se libera.
- **Una fibra es dueña de SQLite** (WAL, `synchronous = FULL`). Los handlers le preguntan por un canal
  con su propio canal de respuesta. Completar una subida multipart es una transacción: el objeto
  aparece y la subida desaparece a la vez.
- **Completar una multipart une las partes por trozos de 1 MiB** a un blob nuevo: nunca tiene el
  objeto entero en memoria. El ETag es el de S3: el MD5 de los MD5 de las partes y `-N`.
- **Las descargas van por `serve_file`**, que trae Range, HEAD y el streaming desde disco en piezas
  de 256 KB. rayblob atiende antes los condicionales con su ETag (el de `serve_file` es tamaño +
  mtime) y luego le pasa la petición.
- **Listar con delimitador** salta cada prefijo común entero con una consulta nueva desde «el primer
  string mayor que todo lo que empieza por el prefijo», así que una carpeta con un millón de claves
  cuesta una fila, no un millón.
- **Anónimo** solo puede leer objetos `public-read`. Quien no puede leer un bucket recibe
  `AccessDenied` también por las claves que no existen, para no revelar cuáles hay.

## Rendimiento

Binario nativo (`make build`) con raylang 1.27.85 en un MacBook (Apple Silicon), cliente `aws` 2.38.5
en la misma máquina:

| | tiempo | pico de RSS del servidor |
|---|---:|---:|
| subir 400 MB (multipart, partes de 8 MiB, 10 en paralelo) | 1,7 s (~230 MB/s) | 529 MiB |
| bajar 400 MB con `aws s3 cp` | 0,7 s | — |
| bajar 400 MB con `curl` y una URL prefirmada | 0,44 s (~920 MB/s) | sin cambio |
| un PUT de 8 MiB / de 64 MiB | — | 55 / 293 MiB |

La memoria de una subida es casi toda del servidor web, que recibe el cuerpo entero (~4,5× su
tamaño, #284). El primer MD5, el de `std/crypto/md5`, llevaba un PUT de 64 MiB a 1,7 GiB y la subida
de 400 MB a 4,5 s; el MD5 incremental de `src/md5.ray` lo dejó en las cifras de arriba (#282). Desde
raylang 1.27.86, `std/crypto/md5` no copia la entrada y tiene `md5_init`, y rayblob vuelve a usarlo.

## Hallazgos de dogfood

En `../findings/open/rayblob-1.27.85.md`. Re-medido con 1.27.86 y net 0.13.0: #280, #281 y #283 arreglados, y sus rodeos quitados; #282 arreglado (md5 ya no copia la entrada y tiene `md5_init`; rayblob quitó su `src/md5.ray`); #284 sigue; #285 arreglado en net 0.14.0, y rayblob usa ya `net/sigv4` (su `src/sigv4.ray`, ~300 líneas, pasó a `net`).

Lo que se encontró con 1.27.85:

- **#280 [B] nativo**: `send(ch, Result.Ok(0))` a un `Channel<Result<int, string>>` genera Rust que no
  compila (E0282). Rodeo: anotar el valor en un `let` (`src/index.ray`).
- **#281 [B] nativo**: `.unwrap()` sobre un `Result` cuyo error es un struct propio no compila (falta
  `Debug`), ni con `@derive(Show)`. Rodeo: `.ok().unwrap()` (`tests/sigv4_test.ray`).
- **#282 [E]**: `std/crypto/md5` no es incremental, cuesta ~23× la entrada en memoria y ~20× el tiempo
  de sha256. rayblob lleva su propio MD5 (140 líneas, 1,6× más rápido, memoria acotada).
- **#283 [B] net**: un `Content-Length` puesto por el handler sale dos veces; aws-cli lo rechaza.
- **#284 [E] net**: el cuerpo de la petición siempre llega entero, y el 413 por tamaño sale en texto
  plano antes del handler (S3 espera `EntityTooLarge` en XML).
- **#285 [E] net**: `net/sigv4` solo firma como cliente, y siempre hashea el cuerpo; un servidor S3
  necesita verificar, prefirmar y encadenar chunks, así que rayblob trae su `sigv4.ray`.

Lo que salió bien: SigV4 pasó los siete ejemplos de la documentación de AWS a la primera, y el `aws`
CLI funcionó contra el servidor en el primer intento salvo por #283. `std/xml`, `db/sqlite`,
`fs.sync_data` + `fs.rename` y el patrón actor compusieron sin fricción.
