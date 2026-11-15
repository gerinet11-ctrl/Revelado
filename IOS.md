# Moon como app de iPhone

En la carpeta `ios/` está el proyecto de Xcode de Moon, ya preparado: icono, pantalla de arranque,
permisos y la app dentro. No hace falta instalar nada más que Xcode.

## Lo que necesitas
- Un Mac con **Xcode 26 o más nuevo** (se instala gratis desde la App Store del Mac).
- Tu cuenta del **Apple Developer Program** ya activada (el correo de bienvenida de Apple).
- Tu iPhone y su cable.

## Probarla en tu iPhone
1. **Descarga el proyecto.** En la página del repositorio en GitHub pulsa el botón verde **Code** y luego
   **Download ZIP**. Descomprime el archivo.
2. **Ábrelo en Xcode.** Dentro de la carpeta, entra en `ios` → `App` y haz doble clic en `App.xcodeproj`.
   La primera vez Xcode descarga una pieza llamada Capacitor; tarda uno o dos minutos y necesita internet.
3. **Pon tu cuenta.** En Xcode: menú **Xcode → Settings → Accounts**, pulsa **+** y entra con tu Apple ID.
4. **Firma la app.** En la columna izquierda pulsa **App** (el icono azul de arriba), luego la pestaña
   **Signing & Capabilities**. Marca **Automatically manage signing** y en **Team** elige tu nombre.
5. **Conecta el iPhone** con el cable y acepta «Confiar en este ordenador». En el iPhone activa
   **Ajustes → Privacidad y seguridad → Modo de desarrollador** (te pedirá reiniciar).
6. **Ejecuta.** Arriba en Xcode elige tu iPhone en la lista de dispositivos y pulsa el botón ▶.
   Moon se instala y se abre en el iPhone.

## Subirla a TestFlight y a la App Store
1. Entra en **appstoreconnect.apple.com → Apps → + → Nueva app**. Plataforma iOS, idioma español,
   identificador `com.gerinet11.moon` y un SKU cualquiera (por ejemplo `moon-1`).
2. En Xcode, arriba, elige **Any iOS Device** en la lista de dispositivos.
3. Menú **Product → Archive**. Al terminar se abre una ventana: pulsa **Distribute App → App Store Connect → Upload**.
4. A los pocos minutos la versión aparece en App Store Connect, pestaña **TestFlight**. Desde ahí invitas a
   tus testers y, cuando quieras, la envías a revisión.

## Cuando haya una versión nueva de Moon
Vuelve a descargar el ZIP del repositorio, abre el proyecto y repite «Archive». Antes, en la pestaña
**General** de Xcode, sube en uno el número de **Build**.

## Datos del proyecto
- Identificador de la app: `com.gerinet11.moon` (se puede cambiar en Xcode, pestaña **General**).
- Solo iPhone, en vertical, iOS 15 o posterior.
- La app web que va dentro está en `ios/App/App/public` y es la misma que se publica en la web.
- Para desarrolladores: `npm install` y `npm run ios` vuelven a copiar la app web al proyecto.
