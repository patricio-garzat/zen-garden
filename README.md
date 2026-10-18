# Zen Garden

Jardín zen japonés interactivo para iPhone, de **BluBer Games**. App **nativa**: Swift + SwiftUI + Metal + Core Haptics + AVAudioEngine. Sin WebView, sin dependencias externas.

Estado: **Fase 1 (Core Experience)**, versión 0.1.0. Compila sin errores en Xcode 26 y se probó en el simulador (iPhone 17) y en un iPhone 14 Pro.

## Qué hay en la Fase 1

- **Arena de verdad:** heightmap en la GPU (768 × 1536 en Equilibrado). Cada rastrillo da forma a la arena (surcos y crestas de arena desplazada); no pinta encima. El relieve se queda hasta que lo borras.
- **Iluminación:** normales, oclusión en el fondo de los surcos y sombras propias calculadas en la GPU. Grano de arena con destellos de cuarzo. Sombras del marco y de las piedras. De día con luz cálida; en modo oscuro, luz de atardecer.
- **4 herramientas:** rastrillo fino (8 dientes), rastrillo ancho (5 dientes profundos), rastrillo de ondas (curvas fluidas; un toque dibuja ondas concéntricas y, sobre una piedra, la rodea de ondas) y alisador (borra poco a poco).
- **Alisar todo:** una tabla barre el jardín de arriba abajo, con su sonido y vibración.
- **Trazo suave:** el rastrillo sigue al dedo con una "correa" y curvas cuadráticas entre muestras, así no salen esquinas ni huecos aunque el dedo vaya rápido.
- **5 piedras procedurales** (Río, Montaña, Basalto, Musgo, Pizarra): caen con gravedad y se asientan sin rebote, empujan un borde de arena, se arrastran, se giran con dos dedos y se quitan sacándolas de la arena. El rastrillo nunca pasa por debajo de una piedra.
- **Granos de arena** (partículas con pool fijo) al rastrillar, al caer una piedra y en el barrido.
- **Sonido ASMR procedural** (AVAudioEngine): fricción + granos + cuerpo grave que cambian con la velocidad, la herramienta y el inicio del trazo. Sesión `ambient` (regla del estudio).
- **Core Haptics:** vibración continua muy suave que sigue la velocidad, "granos" al pasar los dientes, impacto según el tamaño de la piedra, toque ligero en cada botón. Se ajusta o apaga en Ajustes. Si el equipo no tiene Core Haptics, usa `UIImpactFeedbackGenerator`.
- **Deshacer / rehacer** (10–12 pasos, guarda arena y piedras).
- **Guardado:** el jardín en curso se guarda solo (y al salir de la app). Galería "Mis jardines" con miniaturas. Exportar imagen a Fotos (pide permiso).
- **Rendimiento:** solo se recalcula la zona que cambió; el render se pausa cuando no pasa nada y en segundo plano; 3 calidades (Eco, Equilibrado, Ultra) y modo Auto que baja la calidad si la GPU va lenta.
- **App completa:** intro de BluBer (la oficial, con dos sonidos del juego), intro del juego, Inicio, Ajustes (sonido, vibración, tema, idioma, gráficos, borrar datos, Acerca de), Cómo jugar y Récords. Inglés por defecto, español en Ajustes.

## Instalar en tu iPhone (sin App Store Connect ni TestFlight)

### Una sola vez

1. **Xcode 26** instalado. Si al compilar sale *"missing Metal Toolchain"*, corre:
   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```
2. **Abrir el proyecto:** doble clic en `ZenGarden.xcodeproj`.
3. **Equipo de firma:** ya viene puesto el equipo **Patricio Garza T** (`CGW77RJS5Q`) con **firma automática**. Para cambiarlo: selecciona el proyecto azul *ZenGarden* → target *ZenGarden* → pestaña **Signing & Capabilities** → **Team**. Deja marcado *Automatically manage signing*. Si tu cuenta no aparece: Xcode → Settings → Accounts → **+** → Apple ID.
4. **Conectar el iPhone:** con cable USB-C/Lightning (o en la misma red Wi-Fi después de la primera vez). Desbloquéalo y toca **Confiar** en esta computadora.
5. **Modo de desarrollador** (solo la primera vez en ese iPhone): en el iPhone, Ajustes → Privacidad y seguridad → **Modo de desarrollador** → activar → reiniciar → confirmar. Si no aparece la opción, conecta el iPhone y abre Xcode una vez; aparece sola.

### Compilar e instalar

- **Desde Xcode:** arriba elige tu iPhone como destino y presiona **▶ Run** (⌘R). El esquema usa la configuración *Release* para que el audio y la arena vayan optimizados.
- **Desde la Terminal (sin abrir Xcode):**
  ```bash
  ./tools/dev-install.sh
  ```
  Compila, instala y abre la app en el iPhone conectado.

### Instalar versiones nuevas

Repite **▶ Run** o `./tools/dev-install.sh`. La app se actualiza encima de la anterior: **tus jardines, récords y ajustes se conservan**, porque viven en *Application Support* de la app y el bundle id (`com.blubergames.zengarden`) no cambia. Solo se borran si eliminas la app del iPhone o usas *Ajustes → Borrar jardines y récords*.

### Si usas una cuenta de Apple gratuita

- El perfil de desarrollo **caduca a los 7 días**: la app deja de abrir y hay que volver a instalarla desde Xcode (los datos se conservan si no la borras).
- Máximo **3 apps** de desarrollo instaladas a la vez y 10 bundle ids por semana.
- Con la cuenta de pago del estudio (la que ya está configurada) el perfil dura **1 año**.

## Estructura

```
ZenGarden/
├── ZenGarden.xcodeproj      Carpetas sincronizadas: los archivos nuevos entran solos al proyecto
├── Info.plist               Pantalla de arranque blanca (para la intro de BluBer)
├── tools/
│   ├── dev-install.sh       Compila e instala en el iPhone
│   └── make-icon.py         Ícono provisional
└── ZenGarden/
    ├── App/                 ZenGardenApp, AppModel (navegación), GardenEngine (coordinador), GardenUIState
    ├── Views/               Intro de BluBer, Inicio, controles del jardín, Ajustes, Cómo jugar, Récords, Galería, íconos
    ├── Rendering/           GardenRenderer (MTKView), cámara fija, marco de madera, tipos compartidos con Metal
    ├── Shaders/             SandCompute.metal (motor de arena) y Scene.metal (arena, madera, piedras, granos)
    ├── Simulation/          SandSimulation: heightmap, sellos, barrido, deshacer, lectura y carga
    ├── Tools/               ToolSpec (medidas de cada rastrillo) y RakeController (toques → trazos)
    ├── Stones/              Catálogo, mallas procedurales y StoneManager
    ├── Particles/           ParticleSystem (granos de arena)
    ├── Audio/               AudioManager, voz continua de arena y sonidos sintetizados
    ├── Haptics/             HapticsManager (Core Haptics + respaldo)
    ├── Models/              GardenDocument, StoneState, GameProgression
    ├── Persistence/         GardenStore (jardín actual y galería)
    ├── Settings/            SettingsManager y textos en/es (función T)
    ├── Utilities/           Matemáticas, ruido, curvas, parser de SVG
    └── Resources/           Assets (ícono, colores)
```

**Para ajustar cómo se siente cada herramienta:** `Tools/ToolSpec.swift` (dientes, separación, profundidad, correa). **Para la luz:** `applyLighting()` en `App/GardenEngine.swift`. **Para el sonido:** `ScrapeProfile.params` en `Audio/AudioManager.swift`.

## Sonidos: cómo reemplazarlos por grabaciones reales

Hoy todos los sonidos son procedurales (no hay archivos). Para usar grabaciones, copia el archivo a `ZenGarden/Resources/Sounds/` (se agrega solo al proyecto) con uno de estos nombres y extensión `.wav`, `.caf`, `.m4a` o `.aif`. Si existe, se usa en lugar del sintetizado:

| Archivo | Cuándo suena |
|---|---|
| `stone_place_small` | Piedra pequeña que se asienta |
| `stone_place_large` | Piedra grande que se asienta |
| `stone_lift` | Levantar o quitar una piedra |
| `tool_select` | Cambiar de herramienta |
| `ui_tap` | Botones |
| `pattern_complete` | Premio (reservado para Patrones Zen) |
| `intro_swish` | Intro de BluBer, cuando sube "BluBer" |
| `garden_swap` | Abrir un jardín guardado |
| `rake_fine_loop` | Rastrillo fino (loop; el volumen y la velocidad siguen al dedo) |
| `rake_wide_loop` | Rastrillo ancho (loop) |
| `rake_wave_loop` | Rastrillo de ondas y ondas concéntricas (loop) |
| `smoother_loop` | Alisador y "alisar todo" (loop) |

## Qué falta (siguientes fases)

- **Fase 2:** afinar el sonido con audífonos en el iPhone (los niveles se ajustaron sin escucharlos), más detalle en piedras y madera, transiciones de menú.
- **Fase 3:** Zen Points y desbloqueables (el modelo `GameProgression` ya cuenta trazos, distancia, piedras, ondas y jardines), Patrones Zen, Jardín del día, nuevos tipos de arena y escenarios.
- **Fase 4:** más decoraciones (linterna, bambú, musgo), herramientas nuevas, personalización.
- **Pendiente:** ícono definitivo y nombre definitivo.
