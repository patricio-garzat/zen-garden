# Zen Garden · juego #4 de BluBer Games

> Las reglas del estudio (marca, logo, preferencias, App Store y landing) están en `../CLAUDE.md`, y Claude las lee automáticamente. Este archivo es solo para lo de **este** juego.

## Estado (17 oct 2026)
- **Nombre provisional:** Zen Garden (carpeta `ZenGarden/`, repo `patricio-garzat/zen-garden`).
- **Concepto:** jardín zen japonés. Rastrillar arena, colocar piedras, alisar. Sensorial, premium, calmado.
- **Fase 1 terminada (v0.1.0):** compila en Xcode 26, probado en el simulador e instalado en el iPhone 14 Pro del usuario. Todavía **no** está en App Store Connect (el usuario no lo quiere por ahora).

## Diferencia importante con los otros juegos
- **App nativa** (Swift + SwiftUI + Metal), **no** Capacitor ni HTML. No hay versión web todavía.
- Proyecto `ZenGarden.xcodeproj` con **carpetas sincronizadas** (Xcode 16+): cualquier archivo nuevo dentro de `ZenGarden/` entra solo al target. No hace falta editar el `.pbxproj`.
- Xcode 26 necesita el **Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain` (ya está instalado en esta Mac).
- **Probar en el iPhone:** `./tools/dev-install.sh` (Release, instala y abre). El esquema de Xcode corre en *Release* para que el DSP de audio vaya optimizado.
- **Simulador:** `xcodebuild -project ZenGarden.xcodeproj -scheme ZenGarden -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData build`.

## Cómo está hecho
- **Arena (`Simulation/SandSimulation.swift` + `Shaders/SandCompute.metal`):** heightmap `r32Float` en la GPU (512/768/1024 de ancho según la calidad; el largo sigue la proporción 1 × 2 del jardín). Los rastrillos son **sellos** que acercan la altura al perfil real de un rastrillo (cos de los dientes, crestas redondeadas, valles un poco más marcados, irregularidad con ruido); cruzar un patrón viejo lo borra como en la arena. Cada texel recorre los sellos en orden (sin carreras entre hilos). Luego `deriveSurface` calcula solo la zona sucia: pendientes, cavidad (AO) y **sombra propia** marchando hacia el sol. El fragment shader lee esa textura una sola vez.
- **Tipos de sello:** rastrillo, alisador (redondo, borra `passFlatten` por pasada), borde de piedra (solo cerca del contorno; bug corregido: antes rellenaba los surcos en todo el rectángulo) y ondas concéntricas.
- **Trazo (`Tools/RakeController.swift`):** curvas cuadráticas entre los puntos medios de las muestras del dedo + "correa" (`leash`) por herramienta. El ángulo del rastrillo sigue su propio movimiento. Pasos de ≤ 0.7 texel también en el borde exterior en las vueltas.
- **Piedras:** icosfera subdividida + ruido fractal, base aplanada, hundida 12 %. El rastrillo y la tabla respetan su huella (`Footprint`). Caen con gravedad (sin rebote), dejan un borde de arena y al moverlas queda la marca vieja.
- **Render (`Rendering/GardenRenderer.swift`, `Shaders/Scene.metal`):** mesa con sombra del jardín, arena, marco de madera (perfil con chaflán extruido, vetas procedurales), piedras (minerales procedurales: motas, vetas, musgo en parches) y granos instanciados. MSAA 4×, drawable sRGB. Cámara fija inclinada 20°, FOV 22°.
- **Luz:** día (sol cálido) y modo oscuro = atardecer (sol bajo, cielo frío). `applyLighting()` en `GardenEngine`.
- **Audio (`Audio/`):** sesión **ambient**. Voz continua procedural (SVF de ruido + granos aleatorios + grave) que sigue la velocidad; one-shots sintetizados al arrancar (3 variantes cada uno). Cualquier archivo con el nombre del sonido en el bundle lo reemplaza (lista en `README.md`). Voz 0 = dedo, voz 1 = animaciones.
- **Haptics:** continuo muy suave + "granos" limitados a 25/s + impactos según tamaño. Escala con el ajuste de intensidad.
- **Rendimiento:** el `MTKView` se pausa tras 20 cuadros sin nada que animar y en segundo plano. Calidad Auto: baja un nivel si la GPU promedia > 13.5 ms en 120 cuadros.
- **Guardado:** `Application Support/ZenGarden/current` (se guarda solo a los 2.5 s de cada cambio y de forma síncrona al ir a segundo plano) y `gallery/<id>` con miniatura. Alturas en half float comprimidas con LZFSE. Deshacer: snapshots `r16Float` en la GPU.
- **Intro de BluBer:** `Views/BluBerIntroView.swift` dibuja los trazos **oficiales** (copiados con script de `blubergames-site/brand/intro/bluber-intro.html`, sin tocar) con la misma línea de tiempo y curvas. Sonidos del juego: soplo de arena a 1.2 s y piedra a 2.7 s.
- **Intro del juego:** una piedra cae en el centro y la rodean 7 ondas; aparece "ZEN GARDEN". Luego Inicio sobre ese jardín. Al entrar a Jardín libre se abre el último jardín del jugador con un fundido.

## Identidad
- Paleta propia: arena `#E9E1D1`, tinta `#2F2B26`, musgo `#6F8460` (acento), madera cálida. Nada de los rombos de Cube Swipe ni de los azules del estudio en el juego.
- Tipografía del sistema: títulos en serif (New York) light con espaciado amplio; UI en SF.
- Íconos: SF Symbols de línea y los íconos propios de herramientas (`Views/ToolIcons.swift`). Sin emojis.
- Superficies: Liquid Glass en iOS 26 (`zenGlass`), material translúcido antes.

## Pendiente
- Escuchar y afinar los niveles de sonido en el iPhone con audífonos (se ajustaron sin oírlos).
- Fase 3: Zen Points, desbloqueables, Patrones Zen, Jardín del día, arenas y escenarios.
- Ícono y nombre definitivos. Más adelante: App Store, subdominio y ficha en la landing.
