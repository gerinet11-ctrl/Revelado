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
            print("MOONNATIVE autoprueba pedida; webView=\(bridge?.webView != nil)")
            // Informe del estado de la página, para ver qué pasa por dentro.
            for delay in [6.0, 14.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    let js = "JSON.stringify({auto: window.__moonAutoTest, plat: window.Capacitor && window.Capacitor.getPlatform && window.Capacitor.getPlatform(), plugins: Object.keys((window.Capacitor && window.Capacitor.Plugins) || {}), splash: (document.getElementById('splash')||{}).hidden, title: document.title, errs: window.__errs || []})"
                    self?.bridge?.webView?.evaluateJavaScript(js) { result, error in
                        print("MOONNATIVE estado de la página (\(delay) s): \(String(describing: result)) \(String(describing: error))")
                    }
                }
            }
        }
    }
}
