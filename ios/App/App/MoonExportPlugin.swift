import Foundation
import Capacitor
import Photos

/// Guardado de video rápido: la app web manda el proyecto y los archivos, y aquí se genera el video
/// con la gráfica del iPhone (mucho más rápido que reproducirlo) y se guarda directo en Fotos.
@objc(MoonExportPlugin)
public class MoonExportPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MoonExportPlugin"
    public let jsName = "MoonExport"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "ping", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "uploadInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "beginFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "appendFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "has", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "export", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "progress", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clean", returnType: CAPPluginReturnPromise)
    ]

    private let io = DispatchQueue(label: "moon.export.io")
    private var handles: [String: FileHandle] = [:]
    private var exporter: MoonExporter?
    private var fraction: Double = 0

    private var folder: URL { MoonFileStore.shared.folder }

    @objc func ping(_ call: CAPPluginCall) {
        call.resolve(["ok": true])
    }

    /// Puerto y clave del canal rápido para pasar archivos (el servidor local).
    @objc func uploadInfo(_ call: CAPPluginCall) {
        io.async {
            do {
                let port = try MoonUploadServer.shared.start()
                call.resolve(["port": Int(port), "token": MoonUploadServer.shared.token])
            } catch {
                call.reject(error.localizedDescription, "failed")
            }
        }
    }

    @objc func beginFile(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "archivo"
        io.async {
            guard let f = MoonFileStore.shared.create(name: name) else {
                call.reject("No se pudo crear el archivo", "failed")
                return
            }
            call.resolve(["id": f.id, "path": f.url.path])
        }
    }

    @objc func appendFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let text = call.getString("data") else {
            call.reject("Faltan datos", "failed")
            return
        }
        io.async {
            guard let url = MoonFileStore.shared.url(id), let data = Data(base64Encoded: text) else {
                call.reject("Trozo no válido", "failed")
                return
            }
            if self.handles[id] == nil { self.handles[id] = try? FileHandle(forWritingTo: url) }
            guard let h = self.handles[id] else { call.reject("No se pudo abrir el archivo", "failed"); return }
            h.write(data)
            call.resolve()
        }
    }

    @objc func endFile(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            call.reject("Falta el identificador", "failed")
            return
        }
        io.async {
            try? self.handles[id]?.close()
            self.handles[id] = nil
            guard let url = MoonFileStore.shared.url(id) else {
                call.reject("Archivo desconocido", "failed")
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            call.resolve(["path": url.path, "size": size])
        }
    }

    @objc func has(_ call: CAPPluginCall) {
        let list = call.getArray("paths", String.self) ?? []
        let missing = list.filter { !FileManager.default.fileExists(atPath: $0) }
        call.resolve(["missing": missing])
    }

    @objc func progress(_ call: CAPPluginCall) {
        call.resolve(["fraction": fraction])
    }

    @objc func cancel(_ call: CAPPluginCall) {
        exporter?.cancel()
        call.resolve()
    }

    @objc func clean(_ call: CAPPluginCall) {
        try? FileManager.default.removeItem(at: folder)
        call.resolve()
    }

    @objc func export(_ call: CAPPluginCall) {
        guard let text = call.getString("project"), let data = text.data(using: .utf8) else {
            call.reject("Falta el proyecto", "failed")
            return
        }
        let project: MoonProject
        do { project = try JSONDecoder().decode(MoonProject.self, from: data) }
        catch { call.reject("Proyecto no válido: \(error.localizedDescription)", "failed"); return }
        let save = call.getBool("save") ?? true
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("moon-\(UUID().uuidString).mp4")
        let ex = MoonExporter(project: project)
        exporter = ex
        fraction = 0
        let started = Date()
        Task {
            do {
                if save {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else {
                        call.reject("Sin permiso para guardar en Fotos", "denied")
                        return
                    }
                }
                try await ex.export(to: out) { self.fraction = $0 }
                if save {
                    try await PHPhotoLibrary.shared().performChanges {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
                    }
                    try? FileManager.default.removeItem(at: out)
                }
                self.exporter = nil
                call.resolve(["saved": save, "path": out.path, "seconds": Date().timeIntervalSince(started)])
            } catch let e as MoonError {
                self.exporter = nil
                switch e {
                case .cancelled: call.reject("Guardado cancelado", "cancelled")
                case .missing(let f): call.reject("Falta un archivo: \(f)", "missing")
                case .bad(let m): call.reject(m, "failed")
                }
            } catch {
                self.exporter = nil
                call.reject(error.localizedDescription, "failed")
            }
        }
    }
}
