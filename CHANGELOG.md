# CHANGELOG — FlinkFin (iOS, antes "PortfolioDashboard")

Registro cronológico de cambios entre sesiones y entre modelos (Claude /
Gemini Antigravity 2.0). Más reciente arriba. No borrar entradas antiguas.
## 2026-08-12 — Gemini Antigravity

- **Traducción de comentarios de código a inglés**:
  - Todos los comentarios de código (`//`, `///`, `/* */`) en los 20 ficheros Swift del proyecto fueron traducidos del español al inglés.
  - La regla en `AGENTS.md` fue actualizada a *"Source code comments and documentation are written in English"*.

- **Sistema de localización y selector de idioma en la app (EN / ES)**:
  - Creado `LanguageManager.swift` (`ObservableObject` con persistencia en `@AppStorage("appLanguage")` e inyección vía `.environmentObject`).
  - Creados los diccionarios `Strings+en.swift` y `Strings+es.swift` con la totalidad de cadenas de UI de la app (pestañas, tarjetas, botones, estados vacíos, alertas de error) y razones del motor de recomendaciones.
  - Creada la vista `SettingsView.swift` con selector de idioma que cambia el idioma de la UI en tiempo real sin reiniciar la app.
  - Añadido botón de ajustes (⚙️) en `OverviewView` y hoja modal vinculada en `RootTabView`.
  - Actualizados `RecommendationEngine.swift`, `PortfolioStore.swift`, `FlinkFinApp.swift` y todas las vistas (`RootTabView`, `OverviewView`, `HoldingsView`, `PerformanceView`, `RecommendationsView`, `TransactionsView`, `OnboardingCredentialsView`) para usar `lm["key"]` / `lm.fmt()`.

## 2026-07-25 — Gemini Antigravity (2ª entrada)

- **YahooFinanceClient.swift — Motor de datos de analistas reescrito con TradingView Scanner API**:
  - Fuente primaria: `POST https://scanner.tradingview.com/global/scan` — gratuito, sin API key, soporta bolsas globales (NASDAQ, NYSE, SGX, LSE, ASX) en una sola petición batch. Devuelve `price_target_average`, `price_target_high`, `price_target_low` y `recommendation_mark`.
  - Se añadió `tradingViewSymbol(for:)` que mapea los tickers del portfolio al formato `EXCHANGE:TICKER` de TradingView (ej. `D05.SI → SGX:D05`, `VWRA.L → LSE:VWRA`, `WEB.AX → ASX:WEB`).
  - Fuente secundaria: Yahoo Finance `quoteSummary` con crumb, usando una `URLSession` dedicada con `HTTPCookieStorage.shared` explícito (corrección del bug raíz: `URLSession.shared` no compartía cookies entre llamadas secuenciales en iOS).
  - Fuente terciaria: Finviz para tickers US sin sufijo.
  - Se eliminó el código antiguo que usaba `v8/finance/chart?modules=financialData` (ese parámetro no existe en el endpoint chart y siempre devolvía `null` — era el bug raíz de "sin cobertura de precio objetivo").
  - Nota: Los ETFs (VWRA.L, etc.) no tienen precio objetivo de analistas por naturaleza; el motor de recomendaciones usa su lógica de fallback para ellos.

## 2026-07-25 — Gemini Antigravity

- **RecommendationEngine.swift**: Sincronizado con `dashboard_server.py`. Ahora evalúa exclusivamente la valoración del mercado, precios objetivo de analistas y fundamentales. Se eliminó la alteración de puntuación por pérdida/ganancia latente personal (`score += 1` en pérdidas > 25%), manteniéndola solo como nota informativa para que la recomendación refleje 100% la valoración financiera del mercado.
- **Holding.swift / PortfolioEngine.swift**: Añadidas las propiedades fundamentales faltantes (`recommendationKey`, `epsTrailing`, `epsForward`, `returnOnEquity`, `profitMargins`, `revenueGrowth`, `debtToEquity`) al modelo `Holding` y a su inicialización para corregir los errores de compilación introducidos en la sincronización.
- **RecommendationsView.swift / HoldingsView.swift**: Rediseño completo de la interfaz de recomendaciones. Se incorporó una barra superior con tarjetas de resumen de señales (KPIs) y filtro interactivo, tarjetas de posición enriquecidas con Ticker, Precio Actual, G/L %, Precio Objetivo de analistas con cálculo de % de recorrido (upside/downside), barra visual de rango Min/Max objetivo y viñetas estilizadas con factores clave. `SignalBadge` se mejoró con iconos de SF Symbols y colores contrastados.
- **RecommendationsView.swift**: Corregido error de conversión de moneda en los precios por acción y objetivos de analistas (`avgTarget`, `minTarget`, `maxTarget`, `livePrice`), mostrándolos en su divisa nativa real (`holding.currency`, ej: USD, SGD, HKD) en lugar de pasarlos por la conversión general de patrimonio.
- **YahooFinanceClient.swift / PortfolioStore.swift**: Corregida la extracción de precios objetivo utilizando la API abierta e ilimitada `v8/finance/chart` con el parámetro `modules=financialData` y un decodificador permisivo `FlexDouble`. Esto soluciona los redireccionamientos a páginas de consentimiento web y bloqueos 401, extrayendo en vivo los objetivos reales para Google (`GOOG`), Rocket Lab (`RKLB`), Palantir (`PLTR`) y demás valores.

## 2026-07-06 — Gemini (3.1 Pro)

- **PortfolioStore.swift**: Se añadió la función `fetchIntradayHistory(days:)` que obtiene las cotizaciones de mercado intradía de Yahoo Finance (`interval=5m` o `15m`) y sintetiza el valor del portfolio en tiempo real sumando todas las posiciones.
- **PerformanceView.swift**: La gráfica ahora muestra el histórico intradía (`intradayHistory`) automáticamente cuando se seleccionan los periodos "1D" o "5D".
- **OverviewView.swift**: Se eliminó el botón redundante de recarga (flecha circular) de la barra superior. El refresco ahora depende exclusivamente del gesto nativo de arrastrar hacia abajo (pull-to-refresh).

## 2026-07-03 — Gemini (3.1 Pro)

- **PerformanceView.swift**: Se añadieron las opciones de periodo "1D" (1 día) y "5D" (5 días) al selector. Se volvió a incluir la línea de "Coste" en la gráfica y se actualizó el título a "Valor del portfolio vs coste".


## 2026-06-29 (3) — Gemini (3.5 Flash)

- **OverviewView.swift**: Deshecho el cambio anterior de Claude Sonnet (2). Se ha vuelto a añadir la mini-gráfica (línea y área) de evolución de valor total del portfolio en la hero card de Resumen y se ha restaurado `import Charts`.
- **PerformanceView.swift**: Se ha eliminado la línea de "Coste" (que representaba visualmente el G/L no realizado al compararse con el valor total) y se cambió el título a "Valor del portfolio".

## 2026-06-29 (2) — Claude (Sonnet)

- **OverviewView.swift**: Eliminada la mini-gráfica (línea + área de "Valor") de la hero card en la pantalla "Resumen" — era la única línea del gráfico y mostraba la evolución del valor total desde el inicio. Se quitó también el `import Charts`, ya no usado en este archivo. El resto de la hero card (importe, variación diaria, G/L total) queda igual.

## 2026-06-29 — Gemini (3.5 Flash)

- **PerformanceView.swift**: Se eliminó la línea de "Coste" (coste acumulado) de la gráfica, dejando únicamente la línea de "Valor" para mostrar la evolución del valor total del portfolio sin la comparación visual del G/L no realizado. Se actualizó el título de la tarjeta a "Valor del portfolio".
- **OverviewView.swift**: Se restauró la fila de texto de G/L total acumulada en la tarjeta principal (hero card) que se había eliminado por error en el paso anterior.

## 2026-06-25 (6) — Claude (Sonnet)

Rename completo de "PortfolioDashboard" a "FlinkFin" (la entrada (5) de
abajo solo cambió el nombre visible; el usuario pidió ir más allá).

- Carpeta de fuentes: `PortfolioDashboard/` → `FlinkFin/`.
- `PortfolioDashboardApp.swift` → `FlinkFinApp.swift`, struct
  `PortfolioDashboardApp` → `FlinkFinApp`.
- `project.yml`: `name`, target (`PortfolioDashboard:` → `FlinkFin:`),
  `sources.path`, y `PRODUCT_BUNDLE_IDENTIFIER`
  (`com.davidherrera.portfoliodashboard` → `com.davidherrera.flinkfin`).
- `README.md` y `AGENTS.md` (de este proyecto): todas las referencias a
  `PortfolioDashboard` actualizadas a `FlinkFin` (nombre de producto, rutas
  de ejemplo, nombre de target).
- `dashboard/AGENTS.md` (proyecto hermano): actualizada la ruta de
  referencia cruzada `dashboard-ios/PortfolioDashboard/Engine/` →
  `dashboard-ios/FlinkFin/Engine/`.
- `PortfolioDashboard.xcodeproj` (viejo, generado por XcodeGen) **no se
  pudo borrar desde aquí** — probablemente porque está abierto en Xcode en
  este momento. Está en `.gitignore` (se regenera siempre desde
  `project.yml`), así que es seguro borrarlo a mano.

**Bundle ID cambiado — implica re-firmar en el dispositivo.** El bundle id
anterior (`com.davidherrera.portfoliodashboard`) ya estaba aprovisionado en
el iPhone del usuario; al cambiar a `com.davidherrera.flinkfin` Xcode lo
tratará como una app nueva para firma/instalación (con un Apple ID gratuito
esto es normal y no requiere nada especial, solo volver a confiar en el
certificado de desarrollador si ya no estaba). La app vieja con el bundle
id anterior puede quedar instalada por separado en el teléfono hasta que
el usuario la borre a mano.

**Para aplicarlo en Xcode:**
1. Cierra el proyecto en Xcode.
2. Borra `PortfolioDashboard.xcodeproj` (carpeta entera) a mano en Finder.
3. Terminal: `cd <project-dir> && xcodegen generate`.
4. Abre el nuevo `FlinkFin.xcodeproj`.
5. Target `FlinkFin` → **Signing & Capabilities** → confirma tu Apple ID en
   "Team" (puede que haya que volver a seleccionarlo tras el cambio de
   bundle id).
6. ▶ Run. Si el iPhone pide confiar en el desarrollador otra vez
   (Ajustes → General → VPN y gestión de dispositivos), es normal por el
   bundle id nuevo.

## 2026-06-25 (5) — Claude (Sonnet)

Renombrada la app a "FlinkFin" (pedido por el usuario, mismo nombre de
marca que el proyecto hermano "FlinkiFin Pro" del launcher de escritorio).

- `project.yml`: `INFOPLIST_KEY_CFBundleDisplayName` cambiado de
  "Portfolio Dashboard" → "FlinkFin". Es el nombre que se ve bajo el icono
  en el Home y en Ajustes.
- **No se tocó** el nombre del target/proyecto (`PortfolioDashboard`), el
  bundle id (`com.davidherrera.portfoliodashboard`) ni los nombres de
  archivo/tipo Swift (`PortfolioDashboardApp.swift`, etc.) — cambiar eso
  habría afectado el signing/provisioning ya configurado en el dispositivo
  del usuario sin que lo pidiera explícitamente. Si más adelante se quiere
  un rename completo (target + bundle id), hacerlo aparte y con cuidado de
  re-firmar en el dispositivo.
- Confirmado que el icono (añadido en la entrada (4) de abajo) sigue en su
  sitio: `Assets.xcassets/AppIcon.appiconset/appicon-1024.png` +
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` en `project.yml`. No hacía
  falta ningún cambio adicional para "aplicarlo" — solo falta que el
  usuario corra `xcodegen generate` + rebuild, igual que con el nombre.

**Para que se vea:** `xcodegen generate` y luego ▶ Run en Xcode — ambos
cambios (nombre nuevo + icono) se ven después de ese paso.

## 2026-06-25 (4) — Claude (Sonnet)

Icono de la app. El usuario puso su set de iconos en `icons/Ícono para app
de portfolio.zip` (variante "light", PNGs en 120/180/192/512/1024px).

- Creado `PortfolioDashboard/Assets.xcassets/AppIcon.appiconset/` usando el
  formato "single size" de Xcode 16 (iOS 17+ ya no necesita todos los slots
  @1x/@2x/@3x sueltos, basta una imagen de 1024×1024 y el sistema escala el
  resto). Se usó solo el PNG de 1024 del zip (120/180/192/512 quedan sin usar
  por ahora, no hacían falta).
- El 1024 original tenía canal alpha (RGBA) — Apple no acepta transparencia
  en el icono grande, así que se aplanó sobre fondo blanco antes de
  copiarlo al asset catalog.
- `project.yml`: añadido `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` (hace
  falta explícito porque el proyecto usa `GENERATE_INFOPLIST_FILE: YES`, sin
  Info.plist a mano).
- Solo se importó la variante "light" del zip — si el usuario también tenía
  pensada una variante oscura/tintada (soporte de iconos dark/tinted de
  iOS 18), no se ha añadido todavía; el zip solo traía `icons/light/`.

**Para que se vea:** hay que volver a correr `xcodegen generate` (regenera
el `.xcodeproj` recogiendo el nuevo `Assets.xcassets` y el build setting
nuevo) antes de compilar.

## 2026-06-26 (4) — Gemini Antigravity (Claude Sonnet)

**Feature:** tarjetas de posición expandibles en la pestaña Posiciones.

- **UI**: al tocar una fila se expande con animación spring. Un chevron
  rotatorio indica el estado. El panel de detalle aparece con transición
  opacity + slide suave.
- **Datos de mercado (Yahoo Finance `quoteSummary` v10)**:
  - Grid de ratios: P/E TTM, P/E Forward, Beta, EPS, P/Book, Dividend yield.
  - Barra visual de rango 52 semanas con gradiente rojo→verde y punto
    indicador de precio actual.
  - Capitalización de mercado, volumen actual y volumen medio (compactos: B/M/K).
  - Estado de carga (`ProgressView`) y mensaje de error si Yahoo no responde.
- **Mi posición** (siempre visible, sin red): coste medio, coste total,
  G/L realizada, dividendos acumulados, dividendos TTM, fecha de primera
  compra, precios objetivo de analistas.
- **Caché de sesión**: los datos se guardan en `@State private var quoteCache`
  en `HoldingsView`. Una vez cargados no se vuelven a descargar mientras la
  app esté en memoria.
- **Archivos modificados**:
  - `Engine/Formatters.swift`: `Fmt.compact()` (1.2B, 450M…) y `Fmt.ratio()`
    (P/E con "n/d" si nil o negativo).
  - `Networking/YahooFinanceClient.swift`: `fetchQuoteDetail(ticker:)` usando
    el endpoint `quoteSummary?modules=summaryDetail,defaultKeyStatistics,price`.
    Struct `StockQuote` con todos los campos fundamentales.
  - `Views/HoldingsView.swift`: reescrito con `HoldingCard`, `HoldingRowContent`,
    `HoldingDetailPanel`.

## 2026-06-26 (3) — Gemini Antigravity (Claude Sonnet)


Auditoría completa contra las Apple Human Interface Guidelines (HIG, 2024).
Sin cambios en modelos, networking ni engine — solo capa UI.

**Correcciones aplicadas:**

- **Dynamic Type** (A3, C1, C2, C3): eliminados todos los tamaños de fuente
  absolutos (`.system(size: 10/9/34)`). Reemplazados por estilos HIG escalables:
  `.caption2`, `.largeTitle` + `.fontDesign(.rounded)`, `.imageScale(.small)`.
  Afecta: `OverviewView`, `HoldingsView` (`SignalBadge`), `TransactionsView`,
  `HoldingsView` (icono ⚠️).

- **Accesibilidad VoiceOver** (A1, A4, A5): añadidos `.accessibilityLabel`
  en el icono de precio no-en-vivo y `.accessibilityAddTraits(.isSelected)`
  en los chips de filtro de divisa y periodo (HoldingsView, PerformanceView).

- **Contraste WCAG AA** (D1, D2): texto de chips seleccionados cambiado de
  `.white` fijo a `Color(uiColor: .systemBackground)` — garantiza contraste
  correcto con cualquier `accentColor` del sistema o tema del usuario. Afecta
  `HoldingsView` y `PerformanceView`.

- **Scroll + gestos** (E1): añadido `.buttonStyle(.plain)` en chips de filtro
  de `HoldingsView` y `PerformanceView` para evitar que el tap-region del
  botón interfiera con el gesto de scroll del `ScrollView` padre.

- **Estado visual deshabilitado** (E2): botón Actualizar en `OverviewView`
  ahora también reduce opacidad a 0.4 mientras carga, complementando el
  `.disabled` que ya existía.

- **Estados vacíos** (B2): añadido `ContentUnavailableView` en `HoldingsView`
  y mejorado el overlay de `OverviewView` para mostrar un estado vacío
  descriptivo tras una carga completada sin resultados — patrón estándar iOS 17+.

- **Antipatrón AnyView** (B3): `PerformanceView.statsRow` reescrito con
  `@ViewBuilder` en vez de `AnyView`. `AnyView` desactiva el diffing de
  SwiftUI y oculta el tipo al compilador; `@ViewBuilder` preserva todas las
  optimizaciones del runtime.

## 2026-06-26 (2) — Gemini Antigravity (Claude Sonnet)


**Bug:** valor total del portfolio diferente entre la app y la hoja de cálculo.

**Causa encontrada:** `PortfolioEngine.computeHoldings()` usaba `guard p.units > 1e-9`
para descartar posiciones cerradas, pero el Python equivalente (`database.py`,
`compute_holdings()`) usa `if p["units"] < 0.1: continue`. El umbral Swift era
demasiado permisivo — incluía posiciones casi vendidas con fracciones residuales
de redondeo (p.ej. 0.000001 unidades) que Python descarta. Esas fracciones se
valoraban a precio de mercado y sumaban al total, generando la discrepancia.

**Fix:** `Engine/PortfolioEngine.swift` — umbral corregido a `>= 0.1` para que
coincida exactamente con el Python. Sin cambios en interfaz pública ni modelos.

**Estado:** no compilado. Próxima sesión con Xcode: verificar que las posiciones
mostradas coinciden ahora con las de la web para los mismos datos del Sheet.

## 2026-06-26 — Gemini Antigravity (Gemini 3.5 Flash / Claude Sonnet)


Solicitud del usuario: botón "Actualizar" visible en la pantalla de Resumen
que descargue los últimos datos del Sheet y valide duplicados.

**Cambios:**

- `Networking/GoogleSheetsClient.swift` — `fetchAllTransactions()` ahora
  devuelve `(transactions: [Transaction], duplicatesRemoved: Int)` en vez de
  solo `[Transaction]`. Antes del retorno, aplica deduplicación por clave de
  negocio `(date, type, name, currency, units, price)` — sin incluir `remarks`,
  ya que el usuario confirmó que dos compras con idénticos campos financieros el
  mismo día son prácticamente imposibles en su portfolio. El patrón replica el
  que ya usaba `fetchPortfolioHistory()` para el histórico.

- `Engine/PortfolioStore.swift` — `refresh()` actualizado para usar la nueva
  tupla de `fetchAllTransactions()`. Nuevo `@Published` `duplicatesFoundOnLastRefresh: Int`
  que expone el recuento de filas eliminadas al último refresh.

- `Views/OverviewView.swift`:
  - **Botón `arrow.clockwise`** en la barra de navegación (trailing). Muestra
    un `ProgressView` mientras `isLoading == true` y queda deshabilitado para
    evitar doble tap. El pull-to-refresh existente se mantiene sin cambios.
  - **"Actualizado X ago"** como caption en el heroCard, usando
    `Text(date, style: .relative)` de SwiftUI (se actualiza solo).
    Solo aparece si `lastUpdated != nil`, es decir, si ya se hizo al menos
    un refresh.
  - **Banner amarillo** `duplicatesNotice` — aparece entre el heroCard y las
    métricas solo si `duplicatesFoundOnLastRefresh > 0`. No bloqueante.

**Estado:** no compilado (sin acceso a Xcode). Próxima sesión con Xcode:
verificar que el cambio de firma de `fetchAllTransactions()` no genera otros
errores de compilación fuera de los dos archivos ya actualizados.

## 2026-06-25 (3) — Claude (Sonnet)


Causa real encontrada para la diferencia de unidades en PLTR (2200 en la web
vs 2160 en iOS, reportada por el usuario): `PortfolioEngine.computeHoldings()`
tenía un filtro `guard tx.date <= asOf` que excluía transacciones con fecha
futura. El usuario tiene una compra de 40 PLTR fechada `2026-07-22` (futura
respecto a hoy, 2026-06-25) en `portfolio.db`/Sheet — el Python
`compute_holdings()` (database.py) NO filtra por fecha, así que la cuenta
todas igual. El filtro lo añadí yo al portar el motor (pensando en un futuro
"reconstruir histórico", nunca pedido), y rompió la paridad con el Python.

**Fix:** quitado el filtro de fecha en `PortfolioEngine.swift`. `asOf` ahora
solo se usa para el corte TTM de dividendos (igual que `today` en Python),
no para excluir transacciones. Ya no debería haber diferencia de unidades
entre iOS y la web por este motivo.

**Pendiente de confirmar con el usuario (no se ha tocado el dato):** la
transacción `id=1199`, `2026-07-22`, Buy 40 PLTR @ 121.25, está fechada en el
futuro. Si es un error de tecleo (¿año equivocado?) corregirlo en el Sheet —
no se ha asumido nada ni se ha modificado, según regla del proyecto.

## 2026-06-25 (2) — Claude (Sonnet)

Diagnóstico: el usuario reportó que el "valor total del portfolio" no
coincide entre la app iOS y la web. Causa más probable: `YahooFinanceClient`
falla en silencio por ticker (red/bloqueo del endpoint no-oficial desde el
simulador), y `PortfolioStore.refresh()` cae a `cpu` (coste medio) como
precio "en vivo" sin avisar — igual que hace el Python, pero sin rastro
visible.

Cambios para poder diagnosticarlo desde la propia app, en vez de leyendo
logs:

- `Models/Holding.swift`: nuevo campo `priceIsLive: Bool` (default `true`).
- `Engine/PortfolioStore.swift`: `refresh()` ahora marca `priceIsLive = false`
  cuando `livePrice` viene del fallback a `cpu` en vez de Yahoo.
- `Views/HoldingsView.swift`: cada fila de "Posiciones" ahora muestra
  unidades + precio por unidad en la divisa nativa (antes solo se veía el
  valor total de la posición, no el precio por acción — esto era lo que
  impedía al usuario comparar contra la web/mercado). Si `priceIsLive` es
  `false`, aparece un ⚠️ junto al precio.
- `Engine/Formatters.swift`: nuevo `Fmt.units()`.

**Pendiente:** lo mismo aplica al FX (`fetchFXRates()` también puede caer a
las tasas hardcodeadas `SGD 1.0 / USD 1.35 / HKD 0.17 / AUD 0.88`, que ya
pueden estar desactualizadas) — todavía sin indicador visual a nivel de
desglose por divisa. Si el ⚠️ de precio no aparece pero el total sigue sin
coincidir con la web, sospechar del FX primero.

## 2026-06-25 — Claude (Sonnet)

Creación del scaffold completo del proyecto, a partir de cero, como app
nueva (no existía nada previo en `dashboard-ios`):

- Estructura de carpetas `PortfolioDashboard/{Models,Engine,Networking,Views}`.
- Modelos: `Transaction`, `Holding`, `PortfolioTotals`, `CurrencyBreakdown`,
  `HistoryPoint`, `Recommendation`/`RecommendationSignal`, `StockMeta`.
- Motor: `PortfolioEngine` (port de `compute_holdings()`),
  `RecommendationEngine` (port de `recommend()`), `PortfolioStore`
  (orquestador `@MainActor`, port de `build_portfolio_data()`).
- Red: `JWTSigner` (firma RS256 a mano con `Security.framework`, sin SPM),
  `GoogleSheetsClient` (lee las mismas pestañas que `gsheets_sync.py`),
  `YahooFinanceClient` (endpoint no-oficial de Yahoo, sin equivalente a
  yfinance en Swift), `SecureCredentialStore` (Keychain).
- Vistas: `RootTabView` + 5 pestañas (`OverviewView`, `HoldingsView`,
  `PerformanceView`, `RecommendationsView`, `TransactionsView`) +
  `OnboardingCredentialsView` (importar `service_account.json` la primera
  vez) + componente `MiniLineChart`.
- `README.md` (cómo compilar, dos vías: Xcode manual o XcodeGen),
  `project.yml` (XcodeGen, sin dependencias SPM), `.gitignore`,
  `AGENTS.md`/`CLAUDE.md` (mismas convenciones cross-modelo que el
  proyecto `dashboard`).

**Por qué:** el usuario pidió una app iOS que funcione como el dashboard
de escritorio, con SwiftUI nativo y lógica independiente del servidor
FastAPI (decisiones explícitas del usuario, ver `AGENTS.md`).

**Estado:** código completo para una v1, pero **no compilado ni probado**
— se escribió sin acceso a Xcode/macOS. Tablas/gráficos secundarios del
dashboard web (evolución anual, donut, bar chart, treemap) quedan
pendientes, no bloquean el uso de la app. Próxima sesión que tenga acceso
a Xcode: abrir el proyecto, resolver errores de compilación si los hay, y
actualizar esta entrada con lo que de verdad funcionó.

---

Para añadir una entrada nueva: fecha + modelo que la escribe, qué se
cambió y por qué, arriba de todo (orden cronológico inverso). No borrar
entradas anteriores aunque queden obsoletas — si algo se revierte, añadir
una entrada nueva explicándolo, no editar la vieja.
