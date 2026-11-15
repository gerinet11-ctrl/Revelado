import UIKit
import Capacitor

/// Pantalla principal de Moon: la de Capacitor, con el añadido de guardar en Fotos.
class MoonViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(MoonSavePlugin())
    }
}
