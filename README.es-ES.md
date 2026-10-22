# FPGA GPU

Una pequeña GPU SIMT que se ejecuta en una FPGA Tang Nano 20K, programable en su propio lenguaje, **J++**.

Este proyecto me ayudó a aprender cómo funcionan los modelos de IA bajo el capó.

## Qué es

Una pequeña GPU SIMT: dos núcleos de cómputo, cada uno con su propio planificador de warps, ALUs por carril, LSU, archivos de registros y un contador de programa, ejecutando una instrucción de 16 bits a través de muchos hilos en lockstep.

- **Se ejecuta en hardware real.** Toda la cadena de herramientas —síntesis, place-and-route, cierre de temporización, flasheo de bitstream— está configurada para la Tang Nano 20K.
- **Dos núcleos independientes** que se ejecutan en paralelo, cada uno con su propia memoria de programa y de datos.
- **Características SIMT reales:** planificación multi-warp para ocultar la latencia, una pila de divergencia para ramificaciones (branches) y IDs de hilo/bloque programables.
- **Arnés acelerador impulsado por host:** un receptor UART alimenta un motor DMA que transmite el programa y los datos a la memoria on-chip, lanza la ejecución y devuelve el resultado; todo esto sin una CPU en la placa; la computadora actúa como el host.
- **Su propio lenguaje de programación:** J++, un pequeño lenguaje similar a C con un compilador escrito en Rust, para que puedas escribir kernels de alto nivel y transmitirlos a la FPGA sin tener que ensamblar manualmente opcodes de 16 bits.

## Demo

Escribe un kernel en J++, y un solo comando lo compila, lo transmite a la FPGA a través de UART, lo ejecuta en ambos núcleos e imprime lo que el kernel emite de vuelta:

```bash
make run-jpp JPP=software/demo.jpp READ=2
```

`software/demo.jpp` suma `0..7` en la GPU y hace un `yeet` del resultado; cada núcleo responde con `28` (`0x1C`).

![J++ running on the FPGA](docs/demo.gif)

> Regenerar el GIF (placa conectada, [VHS](https://github.com/charmbracelet/vhs) instalado): `vhs demo/demo.tape`

## Arquitectura

[![Full architecture](docs/gpu_overview.svg)](docs/gpu_overview.svg)

El diseño tiene tres capas: un host que carga y lanza el trabajo, la GPU que lo distribuye entre los núcleos, y los núcleos que lo ejecutan como hilos SIMT.

### Nivel superior (`top.sv`)

La placa funciona como un acelerador impulsado por host sin CPU propia. Un receptor UART alimenta un motor DMA que analiza un pequeño encabezado (tamaño del programa, tamaño de los datos) y transmite el kernel y sus datos a la memoria on-chip. Cuando la carga está completa, el DMA pulsa `gpu_start`; una FSM de armado mantiene la GPU en reset durante unos ciclos para estabilizarse y luego la libera para una sola ejecución. Los resultados que el kernel emite son arbitrados de vuelta al transmisor UART y reflejados en los LEDs. Todo funciona con un único reloj derivado del cristal de 27 MHz mediante un rPLL (27 × 3 = 81 MHz).

### GPU (`gpu.sv`, `dispatcher.sv`)

La GPU contiene dos núcleos de cómputo y un despachador (dispatcher). El despachador es de un solo disparo: entrega el bloque 0 al núcleo 0 y el bloque 1 al núcleo 1, y luego espera a que ambos informen que han terminado. No hay un bucle de re-despacho —el número de núcleos es igual al número de bloques— lo que mantiene el control de lanzamiento trivial para una máquina de tamaño fijo.

Cada núcleo tiene su propia copia de la ROM de programa y su propia memoria de datos. Los núcleos ejecutan contadores de programa independientes, por lo que no pueden compartir un único puerto de lectura de BRAM; duplicar la pequeña ROM es más económico que arbitrar uno. Esto es lo que permite que los dos núcleos funcionen genuinamente en paralelo en lugar de en lockstep entre sí.

### Dentro de un núcleo (`core.sv`, `scheduler.sv`)

[![One SIMT compute core](docs/core_detail.svg)](docs/core_detail.svg)

Un núcleo es un único planificador de warps que impulsa recursos de ejecución compartidos:

- **Scheduler (Planificador)** — posee la máquina de estado del pipeline y, con múltiples warps habilitados, elige qué warp impulsa el pipeline en cada paso. Los warps que se detienen por memoria quedan estacionados (`WARP_WAITING`) mientras un warp listo se ejecuta, ocultando la latencia de carga.
- **Fetcher / Decoder (Buscador / Decodificador)** — buscan la instrucción de 16 bits en el PC del warp actual y la decodifican en señales de control (direcciones de registros, inmediato, op de ALU, op de memoria y banderas de salto).
- **Datapath por carril** — cada hilo en un warp tiene su propia ALU, LSU y archivo de registros, por lo que una instrucción opera sobre los datos de muchos hilos a la vez (el patrón SIMD/SIMT). El archivo de registros incluye registros de solo lectura que contienen el ID de bloque y de hilo de ese hilo, que es como un solo kernel realiza trabajos diferentes por carril.

### El pipeline SIMT

Cada instrucción recorre un pipeline de nueve estados:

```
IDLE → SELECT_WARP → FETCH → DECODE → REQUEST → WAIT → EXECUTE → UPDATE → DONE
```

`REQUEST`/`WAIT` existen para operaciones de memoria. `SELECT_WARP` es donde ocurre la ocultación de latencia: entre instrucciones, el planificador puede cambiar a otro warp. `DONE` es el estado terminal.

### Divergencia de ramificaciones (Branch divergence)

En una arquitectura SIMT, todos los hilos ejecutan una instrucción en lockstep, pero ¿qué pasa si escribes `if (x > 0)` y solo la mitad de los hilos cumplen la condición? El hardware se ve obligado a marchar juntos, por lo que manejamos esto con enmascaramiento activo y una pila de divergencia por hardware.

- **La máscara (divergencia):** cuando un warp encuentra una ramificación divergente, el hardware calcula una máscara activa (ej. `[1, 1, 0, 0]`). Todos los hilos ejecutan físicamente las instrucciones dentro del bloque `if`, pero los hilos que no cumplieron la condición (los `0`) tienen desactivados sus permisos de escritura en registros y memoria. Actúan como "fantasmas": hacen el trabajo pero no dejan rastro.
- **Reconvergencia:** cuando comienza la ramificación, el núcleo inserta un marcador en una pequeña pila interna de hardware. El marcador guarda la máscara original (antes de la división) y el PC de reconvergencia (la dirección donde termina la ramificación). En cada instrucción, el PC compara la máscara activa actual con el punto de reconvergencia en la parte superior de la pila. En el momento en que coinciden, el bloque `if` ha terminado y la máscara se restaura.

### Arquitectura de memoria y arbitraje

La memoria de datos y la de programa están físicamente separadas (una arquitectura Harvard estricta), por lo que cada núcleo puede buscar una instrucción y leer/escribir datos en el mismo ciclo de reloj sin contención.

- **Dimensionamiento:** la memoria de programa tiene 16 bits de ancho, mapeando un opcode de ensamblador por fila. La memoria de datos tiene 8 bits de ancho; este fork amplía el bus de direcciones desde los 8 bits originales (256 bytes) a un espacio de direcciones de 13 bits (8 KB).
- **El árbitro:** debido a que esta es una máquina SIMT, un solo `LDR` significa que múltiples hilos solicitan memoria al mismo tiempo, pero la memoria on-chip tiene un único puerto. El núcleo incluye un árbitro de hardware que congela los hilos, serializa las solicitudes una por una a través del puerto único en ciclos consecutivos, y luego despierta al warp para reanudar la ejecución en lockstep una vez que todos los datos han llegado.

## Arquitectura del Conjunto de Instrucciones (16-bit)

Cada instrucción es una palabra de 16 bits, decodificada como: `[15:12]` opcode · `[11:9]` rd · `[8:6]` rs · `[5:0]` imm (registro `rt` en `[2:0]`).

| Opcode | Mnemónico | Significado / Operación |
| --- | --- | --- |
| `0000` | `FRST`/`FMAC`<br>`FARG`/`FBEST` | **Coprocesador FC-MAC** (sub-fn en `[5:4]`): reset / `acc += rs*rt` / finalizar dígito (añadir bias int32, capturar score logit) / leer LSB del logit. |
| `0001` | `ADD rd,rs,rt` | rd = rs + rt |
| `0010` | `MOV rd,#imm` | rd = imm (inmediato de 6 bits) |
| `0010` | `TID`/`BID`<br>`BDIM rd` | `MOV` con `rs`≠0: rd = threadIdx (R15) / blockIdx (R13) / blockDim (R14) |
| `0011` | `CMP rs,rt` | establece banderas N/Z/P (Negativo, Cero, Positivo) |
| `0100` | `LDR rd,[rs]` | rd = mem[rbase + rs] (cargar desde memoria) |
| `0101` | `ADDI rd,rs,#imm` | rd = rs + imm |
| `0110` | `MACL rs` | inserta un par de operandos en el buffer MAC vectorial de 8 carriles |
| `0111` | `MAC rd,#n` | dispara el MAC vectorial $\rightarrow$ extrae el byte `#n` (0–3) de la suma de 32 bits en rd |
| `1000` | `BRn target` | salto si N (objetivo de 8 bits, inserta máscara en la pila en caso de divergencia) |
| `1001` | `ADDB #imm` / `WBASE #imm` | avanza base de lectura / base de escritura (`[11]` selecciona) |
| `1010` | `MUL rd,rs,rt` | rd = rs · rt |
| `1011` | `STR rt,[rs]` | mem[wbase + rs] = rt (almacenar en memoria; `rs`==63 $\rightarrow$ UART TX) |
| `1100`/`1101`/`1110` | `SHR`/`SHL`/`SUB` | desplazamiento derecha / desplazamiento izquierda / resta |
| `1111` | `RET` | detiene el hilo |
| `1111` | `SYNC` | saca la pila de reconvergencia, intercambia máscara de hilos activos (`[0]`=1) |
| _(pseudo)_ | `MAX rd,ra,rb` | macro expandida por el ensamblador (`CMP` + `BRn` + `ADDI`) |

> **Nota sobre registros:** solo **R0–R7** son direccionables por instrucción (campos de 3 bits). R13–R15 son registros de identidad SIMT, legibles mediante `TID`/`BID`/`BDIM` (que los copian en un registro R0–R7).

Esta es una expansión sustancial sobre las 11 instrucciones del tiny-gpu original. Las adiciones (ops de coprocesador MAC/FC, ops de desplazamiento, registros de puntero base, `SYNC`) permiten que cargas de trabajo reales de producto punto y vectoriales se ejecuten sin disparar el conteo de instrucciones. Algunas están codificadas para evitar agotar los opcodes: `WBASE` es `ADDB` con el bit 11 establecido, y `SYNC` es `RET` con el bit 0 establecido; el decodificador los enruta de manera diferente, sin necesidad de un opcode nuevo.

## Cadena de herramientas (Toolchain)

Dos formas de escribir kernels, ambas en `software/` (un crate de Rust).

### Ensamblador

`software/src/main.rs` convierte archivos `.asm` en las palabras de máquina de 16 bits que el DMA transmite. Es un codificador directo de mnemónico a opcode con algunas conveniencias:

- **`ADD` sobrecargado** — un tercer operando precedido por `#` selecciona automáticamente `ADDI`.
- **Pseudo-ops** que se expanden a instrucciones reales: `WBASE`, `SYNC`, `MAX`.
- **Etiquetas** para objetivos de salto, resueltas a direcciones de 8 bits.

```bash
cd software
cargo run -- program.asm        # -> program.hex
```

### J++ — un pequeño lenguaje

Si prefieres no ensamblar a mano, **J++** es un lenguaje similar a C con su propio compilador (lexer $\rightarrow$ parser $\rightarrow$ codegen, todo en `software/src/`). Baja el flujo de control de alto nivel directamente a ensamblador de tiny-gpu:

- `manifest x = …` — declara una variable (asignada a registro)
- `grind_until (cond) { … }` — bucle, bajado a `CMP` + salto
- `yeet expr` — emite un byte de resultado (almacenamiento en UART mapeado en memoria)
- `tid` / `bid` / `bdim` — lee la identidad SIMT de este carril (threadIdx / blockIdx / blockDim), para que los kernels puedan hacer trabajo por carril
- `crunch_push` / `crunch_fire` — impulsa el coprocesador MAC desde la fuente

```bash
cd software
cargo run --bin jpp -- program.jpp program.asm   # J++ -> asm
cargo run -- program.asm                          # asm -> hex
```

Por lo tanto, la ruta completa desde el código fuente hasta el silicio es: **`.jpp` $\rightarrow$ `.asm` $\rightarrow$ `.hex` $\rightarrow$ UART $\rightarrow$ GPU.**

## Simulación

No necesitas la placa para ejecutar o verificar nada; todo el diseño se simula bajo Icarus Verilog, y cada objetivo es **autoverificable** (afirma el resultado esperado y falla ruidosamente si el hardware es incorrecto). Sin cocotb, sin pegamento de Python para las simulaciones del núcleo; solo `iverilog` + `vvp`.

```bash
make sim             # prueba de humo: el kernel computa 5 * 3 = 15
make sim-loadrun     # ruta completa: transmite kernel + datos por UART, ejecuta, verifica respuesta
make sim-divergence  # divergencia SIMT por carril — los carriles toman ramas diferentes
make sim-divmerge    # divergencia + reconvergencia — el código compartido se reanuda en todos los carriles
make sim-warps       # dos warps ejecutan IDs de hilo globales distintos (8 carriles, 0..7)
make sim-mac32       # el resultado MAC de 32 bits se lee byte por byte
make sim-mlp         # capa FC paralela: 9 carriles escriben su propia neurona
```

Estos sirven también como especificación: cada uno es la prueba mínima de que una característica SIMT específica (divergencia, IDs de warp, la ruta MAC) realmente funciona.

## Construcción y flasheo

Dos rutas de síntesis, ambas dirigidas a la Tang Nano 20K (Gowin GW2AR-18).

### Cadena de herramientas de código abierto (recomendada)

Yosys + nextpnr-himbaechel + apicula. **Esta es la ruta validada** — el `GowinSynthesis` del proveedor da segfault con el diseño multi-warp, por lo que el flujo de código abierto es el que realmente produce bitstreams funcionales aquí.

```bash
export OSS_CAD_SUITE=/ruta/a/oss-cad-suite   # desde YosysHQ/oss-cad-suite-build
make build-oss        # -> oss_build/tiny_gpu_oss.fs
make flash-oss        # cargar en SRAM (volátil)
```

Para la configuración más grande capaz de ejecutar IA (2 núcleos × 1 warp × 9 carriles = 18 carriles ALU, ~78% LUT, 140 MHz):

```bash
make build-oss-max    # -> oss_build/tiny_gpu_max18.fs
make flash-oss-max
```

### Cadena de herramientas del proveedor

El flujo de Gowin sigue conectado (`build_fpga.sh` / `flash.sh`) para configuraciones de un solo warp:

```bash
make build            # -> impl/pnr/tiny_gpu.fs
make flash            # SRAM (volátil)
make flash-persist    # escribir en flash SPI (sobrevive al ciclo de encendido)
```

`flash` carga en SRAM y se pierde al apagar la placa, ideal para iterar. `flash-persist` graba la flash SPI externa para que el diseño arranque por sí solo.

### Extremo a extremo

Una vez que el bitstream está en la placa, todo el pipeline `.jpp $\rightarrow$ asm $\rightarrow$ hex $\rightarrow$ UART $\rightarrow$ GPU $\rightarrow$ resultado` es un solo comando:

```bash
make run-jpp JPP=software/tu_kernel.jpp READ=8
```

Eso compila tu fuente de J++, lo ensambla, lo transmite a la FPGA, lo ejecuta e imprime los bytes que el kernel emite de vuelta.

### Prerrequisitos

- **Rust** (`cargo`) — ensamblador + compilador J++
- **Icarus Verilog** (`iverilog`, `vvp`) — simulación
- **oss-cad-suite** (Yosys, nextpnr-himbaechel, apicula, openFPGALoader) — síntesis + flasheo
- **Python 3** — los scripts de host UART (`send_kernel.py`)

## Síntesis y utilización (Tang Nano 20K · GW2AR-18C)

De `impl/pnr/tiny_gpu.rpt.html`:

| Recurso        | Usado                            | Disponible | Util. |
| --------------- | ------------------------------- | --------- | ----- |
| Lógica (LUT+ALU) | 1501 (1052 LUT4, 449 ALU)       | 20736     | 8 %   |
| Registros       | 878 (877 FF + 1 I/O)            | 15750     | 6 %   |
| CLS (slices)    | 1180                            | 10368     | 12 %  |
| Block SRAM      | 4 SDPB + 1 pROM                 | 46        | 11 %  |
| DSP             | 4× MULT9X9 + 5× MULTADDALU18X18 | —         | 25 %  |
| Puertos I/O     | 9                               | 66        | 14 %  |
| PLL             | 0                               | 2         | 0 %   |

Relojado a **81 MHz** (rPLL, 27 × 3). La configuración máxima de 18 carriles cierra la temporización alrededor de los 140 MHz.

## Diseño del repositorio

```
src/        gpu, core, scheduler, dispatcher, decoder, registers, alu, pc, lsu,
            lsu_arbiter, lsu_write_arbiter, vector_mac (MAC vectorial de 8 carriles),
            fc_mac (FC + argmax), main_memory, program_memory, dma_controller,
            data_pipeline, uart_rx/tx, gowin_pll, top
software/   Crate de Rust: ensamblador (src/main.rs) + compilador J++ (src/bin/jpp.rs);
            kernels de ejemplo (*.asm, *.jpp); scripts de host UART de Python (send_kernel.py)
test/       tb*.sv — bancos de prueba autoverificables (loadrun, divergence, warps, MAC, MLP)
oss_build/  flujo de síntesis de código abierto (run_oss.sh, build_cfg.sh)
*.sh, *.tcl  construcción/flasheo de Gowin sin interfaz en macOS
```
