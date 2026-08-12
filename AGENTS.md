# FlinkFin (iOS) — AGENTS.md

Fuente única de verdad de este subproyecto (también la lee Gemini
Antigravity 2.0). No la dupliques en `CLAUDE.md` — añade reglas o contexto
nuevo aquí. **Cualquier modelo que trabaje aquí (Claude o Gemini) debe leer
este archivo y `CHANGELOG.md` antes de tocar código, y dejar una entrada
nueva en `CHANGELOG.md` al terminar** — es como un modelo se entera de lo
que hizo el otro en la sesión anterior.

## Qué es

App nativa SwiftUI que replica el dashboard financiero de escritorio
(proyecto hermano [`dashboard`](../dashboard), ver su propio `AGENTS.md`)
en iOS. Ver `README.md` de esta carpeta para cómo compilarla y arrancarla.

## Decisiones ya tomadas (no reabrir sin motivo nuevo)

1. **SwiftUI nativo, no WKWebView ni React Native/Flutter.** Elegido por
   el usuario explícitamente al crear este proyecto (2026-06-25).
2. **Lógica independiente, no llama al servidor FastAPI.** La app lee
   directamente de Google Sheets API + el endpoint no-oficial de Yahoo
   Finance con su propia implementación en Swift — no depende de que
   `dashboard_server.py` esté corriendo. Elegido explícitamente por el
   usuario sobre la alternativa de que la app fuera un cliente del backend
   Python. Si en el futuro se reconsidera, recordar que esto fue una
   decisión, no un descuido.
3. **Sin dependencias SPM externas.** El JWT de la cuenta de servicio de
   Google se firma a mano con `Security.framework` de Apple
   (`JWTSigner.swift`) en vez de usar el paquete `jwt-kit`, para no meter
   una dependencia de terceros en el código que firma credenciales. Si
   `JWTSigner.swift` da problemas en Xcode, es preferible depurarlo antes
   que añadir esa dependencia como parche rápido.
4. **Credenciales en Keychain, nunca en el bundle ni en git.** El JSON de
   la cuenta de servicio se importa una vez desde un selector de archivos
   y se guarda con `SecureCredentialStore.swift`
   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). No añadir ninguna
   vía que escriba esa clave en disco sin cifrar, `UserDefaults`, logs, o
   que la hardcodee en código.
5. **`fetchPortfolioHistory()` replica una discrepancia ya existente en el
   Python** entre `parse_history()` (salta 2 filas) y
   `_import_portfolio_history()` (salta 1 fila) — ver comentario en
   `Networking/GoogleSheetsClient.swift`. No se ha "corregido"
   unilateralmente porque no está confirmado si es un bug o intencional
   (cabecera de 2 filas en esa pestaña del Sheet). Si se investiga y se
   confirma que es un bug, corregirlo en **ambos** proyectos a la vez y
   anotarlo en los dos `CHANGELOG.md`.
6. **Tablas/gráficos pendientes, no bloqueantes:** evolución anual, donut
   de asignación por divisa, bar chart de top 10, treemap de
   concentración (sí están en el dashboard web, `templates/index.html`).
   Se pueden derivar de los datos que ya expone `PortfolioStore` sin
   tocar la capa de red — quedan como mejora de UI, no de arquitectura.

## Reglas (heredadas del proyecto `dashboard`, aplican igual aquí)

1. Nunca modificar el proyecto externo `portfolio-manager` (es referencia,
   de otro proyecto).
2. Nunca escribir en el Google Sheet del usuario — esta app es de **solo
   lectura** contra Sheets. Si en algún momento se plantea añadir
   transacciones desde la app, no escribir directamente sobre las pestañas
   "Transactions *" existentes — preguntar al usuario primero por el
   diseño (¿pestaña nueva? ¿solo en local?).
3. Nunca ejecutar operaciones financieras reales (compra/venta) desde esta
   app — solo lectura y recomendaciones informativas, igual que el
   dashboard web.
4. Mantener `PortfolioEngine.swift` / `RecommendationEngine.swift` en sync
   con `compute_holdings()` / `recommend()` del proyecto `dashboard`. Si
   cambia uno, cambiar el otro y anotarlo en ambos `CHANGELOG.md`.
5. No se ha podido compilar este código todavía (se escribió sin acceso a
   Xcode/macOS) — la primera sesión que lo abra en Xcode debe esperar
   pequeños errores de compilación y corregirlos, no asumir que está
   verificado.
6. Documentar cambios en `CHANGELOG.md` (de esta carpeta).

## Idioma

Comunicación con el usuario en español, respuestas concisas. Comentarios
de código en español, igual que en el proyecto `dashboard`.
