import Foundation
import Capacitor
import Photos

/// Guarda en Fotos un archivo que la app web envía por trozos (así caben también los videos grandes).
/// Pasos: `begin` crea un archivo temporal, `append` le añade cada trozo y `finish` lo pasa a Fotos.
@objc(MoonSavePlugin)
public class MoonSavePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MoonSavePlugin"
    public let jsName = "MoonSave"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "begin", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "append", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finish", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]

    private var files: [String: URL] = [:]
    private var handles: [String: FileHandle] = [:]
    private let queue = DispatchQueue(label: "moon.save")

    @objc func begin(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "moon"
        let ext = (name as NSString).pathExtension
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moon-\(id).\(ext.isEmpty ? "bin" : ext)")
        queue.async {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                call.reject("No se pudo crear el archivo temporal", "failed")
                return
            }
            self.files[id] = url
            self.handles[id] = handle
            call.resolve(["id": id])
        }
    }

    @objc func append(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let text = call.getString("data") else {
            call.reject("Faltan datos", "failed")
            return
        }
        queue.async {
            guard let handle = self.handles[id], let data = Data(base64Encoded: text) else {
                call.reject("Trozo no válido", "failed")
                return
            }
            handle.write(data)
            call.resolve()
        }
    }

    @objc func finish(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Falta el identificador", "failed")
            return
        }
        let isVideo = (call.getString("kind") ?? "image") == "video"
        queue.async {
            guard let url = self.files[id] else {
                call.reject("Archivo desconocido", "failed")
                return
            }
            try? self.handles[id]?.close()
            self.handles[id] = nil
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    self.remove(id)
                    call.reject("Sin permiso para guardar en Fotos", "denied")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    if isVideo {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }, completionHandler: { saved, error in
                    self.remove(id)
                    if saved {
                        call.resolve()
                    } else {
                        call.reject(error?.localizedDescription ?? "No se pudo guardar en Fotos", "failed")
                    }
                })
            }
        }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        if let id = call.getString("id") {
            queue.async {
                try? self.handles[id]?.close()
                self.handles[id] = nil
            }
            remove(id)
        }
        call.resolve()
    }

    private func remove(_ id: String) {
        queue.async {
            if let url = self.files[id] {
                try? FileManager.default.removeItem(at: url)
            }
            self.files[id] = nil
        }
    }
}
