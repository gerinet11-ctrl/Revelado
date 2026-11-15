import UIKit
import Capacitor
import WebKit

/// Pantalla principal de Moon: la de Capacitor, con el añadido de guardar en Fotos.
class MoonViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(MoonSavePlugin())
        bridge?.registerPluginInstance(MoonExportPlugin())
        // Solo en las pruebas automáticas: la app se prueba a sí misma al arrancar.
        if ProcessInfo.processInfo.arguments.contains("-moonSelfTest") {
            let script = WKUserScript(source: "window.__moonAutoTest = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
            bridge?.webView?.configuration.userContentController.addUserScript(script)
        }
    }
}
