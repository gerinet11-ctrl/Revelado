import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
@testable import MoonExport

final class MoonExportTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("moon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        if MTLCreateSystemDefaultDevice() == nil { throw XCTSkip("Este Mac no tiene Metal") }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    // MARK: ayudas

    typealias RGB = (r: Int, g: Int, b: Int)

    /// Video de prueba: `draw` pinta cada fotograma. `rotate` lo graba como un video vertical de iPhone.
    func makeVideo(_ name: String, w: Int, h: Int, seconds: Double, rotate: Bool = false, draw: @escaping (CGContext, Int, Int) -> Void) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        if rotate { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            let b = pb!
            CVPixelBufferLockBaseAddress(b, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            // Origen arriba a la izquierda, como una pantalla
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            draw(ctx, w, h)
            CVPixelBufferUnlockBaseAddress(b, [])
            XCTAssertTrue(adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func solid(_ r: Int, _ g: Int, _ b: Int) -> (CGContext, Int, Int) -> Void {
        return { ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func writePNG(_ name: String, w: Int, h: Int, draw: (CGContext) -> Void) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func identity() -> MoonProject.Look {
        MoonProject.Look(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0], shadows: 0, highlights: 0, split: 0, vignette: 0, grain: 0, flash: 0)
    }

    func clip(_ file: URL, s: Double = 0, e: Double, kind: String = "video", tr: String = "none") -> MoonProject.Clip {
        MoonProject.Clip(kind: kind, file: file.path, s: s, e: e, tr: tr, vol: 100, scale: [1, 1], off: [0, 0])
    }

    func project(w: Int, h: Int, clips: [MoonProject.Clip], speed: Double = 1, look: MoonProject.Look? = nil, overlays: [MoonProject.Overlay] = [], music: MoonProject.Music? = nil, voice: MoonProject.Voice? = nil) -> MoonProject {
        MoonProject(width: w, height: h, fps: 30, speed: speed, vol: 100, trDur: 0.5, look: look ?? identity(), clips: clips, overlays: overlays, music: music, voice: voice)
    }

    func run(_ p: MoonProject) async throws -> URL {
        let out = tmp.appendingPathComponent("salida-\(UUID().uuidString).mp4")
        var last = 0.0
        try await MoonExporter(project: p).export(to: out) { last = $0 }
        XCTAssertGreaterThan(last, 0.99)
        return out
    }

    func frame(_ url: URL, at t: Double) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        return try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
    }

    func pixel(_ img: CGImage, _ fx: Double, _ fy: Double) -> RGB {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let x = min(w - 1, Int(fx * Double(w))), y = min(h - 1, Int(fy * Double(h)))
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    func near(_ a: RGB, _ b: RGB, _ tol: Int = 16, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol && abs(a.b - b.b) <= tol, "obtenido \(a), esperado \(b) ±\(tol)", file: file, line: line)
    }

    func duration(_ url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    func rms(_ url: URL, from: Double, to: Double) throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        var sum = 0.0, n = 0.0
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var bytes = [UInt8](repeating: 0, count: len)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for v in s { let f = Double(v) / 32768; sum += f * f; n += 1 }
            }
        }
        return n > 0 ? (sum / n).squareRoot() : 0
    }

    func makeTone(_ name: String, seconds: Double, hz: Double) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(seconds * 44100)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = Float(0.5 * sin(2 * Double.pi * hz * Double(i) / 44100)) }
        try file.write(from: buf)
        return url
    }

    // MARK: pruebas

    func testIdentityAndSpeed() async throws {
        let v = try makeVideo("a.mp4", w: 320, h: 180, seconds: 2, draw: solid(200, 60, 40))
        let out = try await run(project(w: 320, h: 180, clips: [clip(v, e: 2)], speed: 2))
        let d = try await duration(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.2, "a velocidad ×2 el video de 2 s debe durar 1 s")
        near(pixel(try frame(out, at: 0.5), 0.5, 0.5), (200, 60, 40))
    }

    func testGrayscaleLook() async throws {
        let v = try makeVideo("a.mp4", w: 320, h: 180, seconds: 1, draw: solid(200, 60, 40))
        var look = identity()
        look.m = [0.2126, 0.7152, 0.0722, 0, 0.2126, 0.7152, 0.0722, 0, 0.2126, 0.7152, 0.0722, 0]
        let out = try await run(project(w: 320, h: 180, clips: [clip(v, e: 1)], look: look))
        let c = pixel(try frame(out, at: 0.4), 0.5, 0.5)
        XCTAssertLessThan(abs(c.r - c.g), 10); XCTAssertLessThan(abs(c.g - c.b), 10)
        XCTAssertEqual(Double(c.g), 0.2126 * 200 + 0.7152 * 60 + 0.0722 * 40, accuracy: 14)
    }

    func testTwoClipsWithFade() async throws {
        let a = try makeVideo("a.mp4", w: 320, h: 180, seconds: 1, draw: solid(220, 20, 20))
        let b = try makeVideo("b.mp4", w: 320, h: 180, seconds: 1, draw: solid(20, 20, 220))
        let out = try await run(project(w: 320, h: 180, clips: [clip(a, e: 1), clip(b, e: 1, tr: "fade")]))
        let dur2 = try await duration(out)
        XCTAssertEqual(dur2, 2.0, accuracy: 0.2)
        near(pixel(try frame(out, at: 0.5), 0.5, 0.5), (220, 20, 20))
        near(pixel(try frame(out, at: 1.8), 0.5, 0.5), (20, 20, 220))
        let mid = pixel(try frame(out, at: 1.25), 0.5, 0.5)
        XCTAssertGreaterThan(mid.r, 60, "en medio de la transición aún queda rojo: \(mid)")
        XCTAssertGreaterThan(mid.b, 60, "en medio de la transición ya hay azul: \(mid)")
    }

    func testDipToBlack() async throws {
        let a = try makeVideo("a.mp4", w: 320, h: 180, seconds: 1, draw: solid(220, 220, 220))
        let b = try makeVideo("b.mp4", w: 320, h: 180, seconds: 1, draw: solid(220, 220, 220))
        let out = try await run(project(w: 320, h: 180, clips: [clip(a, e: 1), clip(b, e: 1, tr: "black")]))
        let dark = pixel(try frame(out, at: 1.0), 0.5, 0.5)
        XCTAssertLessThan(dark.r, 60, "en la unión debe ser casi negro: \(dark)")
        near(pixel(try frame(out, at: 0.4), 0.5, 0.5), (220, 220, 220))
    }

    func testPortraitVideoIsRotatedUpright() async throws {
        // Origen horizontal 320×180 grabado «de lado»: mitad izquierda roja, derecha azul.
        let v = try makeVideo("p.mp4", w: 320, h: 180, seconds: 1, rotate: true) { ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
        let out = try await run(project(w: 180, h: 320, clips: [clip(v, e: 1)]))
        let img = try frame(out, at: 0.4)
        XCTAssertEqual(img.width, 180); XCTAssertEqual(img.height, 320)
        near(pixel(img, 0.5, 0.25), (217, 26, 26), 24)   // arriba: rojo
        near(pixel(img, 0.5, 0.75), (26, 26, 217), 24)   // abajo: azul
    }

    func testStillPhotoWithTextOverlay() async throws {
        let photo = try writePNG("foto.png", w: 200, h: 120) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        }
        let text = try writePNG("texto.png", w: 200, h: 120) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 80, y: 45, width: 40, height: 30))
        }
        let ov = MoonProject.Overlay(file: text.path, t0: 0, t1: 1e6, x: 0.5, y: 0.5, anim: "none")
        let out = try await run(project(w: 200, h: 120, clips: [clip(photo, e: 1, kind: "still")], overlays: [ov]))
        let dur1 = try await duration(out)
        XCTAssertEqual(dur1, 1.0, accuracy: 0.2)
        let img = try frame(out, at: 0.5)
        near(pixel(img, 0.5, 0.5), (255, 255, 255), 24)
        near(pixel(img, 0.1, 0.1), (204, 26, 179), 24)
    }

    func testOverlayAppearsOnlyInItsTime() async throws {
        let v = try makeVideo("a.mp4", w: 200, h: 120, seconds: 2, draw: solid(120, 120, 120))
        let text = try writePNG("texto.png", w: 200, h: 120) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 80, y: 45, width: 40, height: 30))
        }
        let ov = MoonProject.Overlay(file: text.path, t0: 1.0, t1: 2.0, x: 0.5, y: 0.5, anim: "none")
        let out = try await run(project(w: 200, h: 120, clips: [clip(v, e: 2)], overlays: [ov]))
        near(pixel(try frame(out, at: 0.4), 0.5, 0.5), (120, 120, 120))
        near(pixel(try frame(out, at: 1.5), 0.5, 0.5), (255, 255, 255), 24)
    }

    func testMusicAndVoiceAreMixed() async throws {
        let v = try makeVideo("a.mp4", w: 160, h: 90, seconds: 3, draw: solid(50, 50, 50))
        let music = try makeTone("musica.m4a", seconds: 5, hz: 440)
        let voice = try makeTone("voz.m4a", seconds: 1, hz: 880)
        let out = try await run(project(w: 160, h: 90, clips: [clip(v, e: 3)],
                                        music: .init(file: music.path, vol: 40, offset: 0, fade: false),
                                        voice: .init(file: voice.path, at: 1.5, dur: 1, vol: 100)))
        let asset = AVURLAsset(url: out)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "debe haber una pista de sonido")
        let musicOnly = try rms(out, from: 0.2, to: 1.2)
        let both = try rms(out, from: 1.7, to: 2.3)
        XCTAssertGreaterThan(musicOnly, 0.05, "se oye la música")
        XCTAssertGreaterThan(both, musicOnly * 1.2, "con la voz encima suena más fuerte")
    }

    func testPanAndZoomChangeWhatIsVisible() async throws {
        // Video con la mitad izquierda roja y la derecha azul; se enseña solo la mitad derecha (zoom ×2 hacia la derecha).
        let v = try makeVideo("a.mp4", w: 320, h: 180, seconds: 1) { ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
        var c = clip(v, e: 1)
        c.scale = [0.5, 1]; c.off = [0.25, 0]
        let out = try await run(project(w: 320, h: 180, clips: [c]))
        let img = try frame(out, at: 0.4)
        near(pixel(img, 0.1, 0.5), (26, 26, 217), 24)
        near(pixel(img, 0.9, 0.5), (26, 26, 217), 24)
    }

    func testMissingFileFailsCleanly() async throws {
        let p = project(w: 160, h: 90, clips: [MoonProject.Clip(kind: "video", file: "/no/existe.mp4", s: 0, e: 1, tr: "none", vol: 100, scale: [1, 1], off: [0, 0])])
        do { _ = try await run(p); XCTFail("debía fallar") } catch MoonError.missing { } catch { XCTFail("error inesperado: \(error)") }
    }

    // MARK: contrato con la app web

    /// Proyecto tal cual lo manda la app web (capturado de una ejecución real). Si cambia la app web, esta prueba avisa.
    func testDecodesProjectSentByWebApp() throws {
        let json = #"""
{"width":640,"height":360,"fps":30,"speed":1.5,"vol":100,"trDur":0.5,"look":{"m":[0.24236400000000005,0.815328,0.082308,-0.07000000000000006,0.24236400000000005,0.815328,0.082308,-0.07000000000000006,0.24236400000000005,0.815328,0.082308,-0.07000000000000006],"shadows":0,"highlights":0,"split":0,"vignette":0,"grain":0,"flash":0},"clips":[{"kind":"video","file":"/cache/f1-prueba-video.mp4","s":0,"e":6,"tr":"none","vol":100,"scale":[1,1],"off":[0,0]},{"kind":"still","file":"/cache/f2-3f0nve8.png","s":0,"e":3,"tr":"fade","vol":100,"scale":[1,0.75],"off":[0,0]}],"overlays":[{"file":"/cache/f4-texto-wab32en.png","t0":0.4,"t1":3.4,"x":0.5,"y":0.5,"anim":"rise"},{"file":"/cache/f5-texto-ck4is6w.png","t0":0.2,"t1":3.2,"x":0.5,"y":0.3,"anim":"pop"}],"music":{"file":"/cache/f3-audio-rat0ljt","vol":80,"offset":0,"fade":true},"voice":null}
"""#
        let p = try JSONDecoder().decode(MoonProject.self, from: Data(json.utf8))
        XCTAssertEqual(p.clips.count, 2)
        XCTAssertEqual(p.clips[1].kind, "still")
        XCTAssertEqual(p.clips[1].tr, "fade")
        XCTAssertEqual(p.look.m.count, 12)
        XCTAssertEqual(p.overlays.count, 2)
        XCTAssertNotNil(p.music)
        XCTAssertNil(p.voice)
        XCTAssertEqual(p.speed, 1.5, accuracy: 0.001)
    }

    // MARK: canal de archivos

    func testUploadServerReceivesBigFile() async throws {
        let server = MoonUploadServer.shared
        let port = try server.start()
        XCTAssertGreaterThan(port, 0)
        let f = try XCTUnwrap(MoonFileStore.shared.create(name: "grande.bin"))
        let bytes = 64 * 1024 * 1024
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: bytes, by: 4096) { raw.storeBytes(of: UInt8(truncatingIfNeeded: i / 4096), toByteOffset: i, as: UInt8.self) } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/put/\(server.token)/\(f.id)")!)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let t0 = Date()
        let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 204)
        let size = (try FileManager.default.attributesOfItem(atPath: f.url.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, bytes)
        let back = try Data(contentsOf: f.url)
        XCTAssertEqual(back, data, "el archivo recibido debe ser idéntico")
        print("CANAL: \(bytes / 1_000_000) MB en \(String(format: "%.2f", dt)) s = \(String(format: "%.0f", Double(bytes) / 1_000_000 / dt)) MB/s")
        XCTAssertLessThan(dt, 20)
    }

    func testUploadServerRejectsWrongKeyAndAnswersPreflight() async throws {
        let server = MoonUploadServer.shared
        let port = try server.start()
        let f = try XCTUnwrap(MoonFileStore.shared.create(name: "x.bin"))
        var bad = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/put/clave-falsa/\(f.id)")!)
        bad.httpMethod = "POST"
        let (_, r1) = try await URLSession.shared.upload(for: bad, from: Data([1, 2, 3]))
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 403)
        var pre = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/put/\(server.token)/\(f.id)")!)
        pre.httpMethod = "OPTIONS"
        let (_, r2) = try await URLSession.shared.data(for: pre)
        let h = r2 as? HTTPURLResponse
        XCTAssertEqual(h?.statusCode, 204)
        XCTAssertEqual(h?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
    }

    // MARK: cancelar y rendimiento

    func testCancelEndsQuickly() async throws {
        let v = try makeVideo("larga.mp4", w: 1280, h: 720, seconds: 20, draw: solid(90, 90, 200))
        let ex = MoonExporter(project: project(w: 1280, h: 720, clips: [clip(v, e: 20), clip(v, e: 20)]))
        let out = tmp.appendingPathComponent("cancelado.mp4")
        let t0 = Date()
        Task { try? await Task.sleep(nanoseconds: 700_000_000); ex.cancel() }
        do { try await ex.export(to: out) { _ in }; XCTFail("debía cancelarse") }
        catch MoonError.cancelled { }
        catch { XCTFail("error inesperado: \(error)") }
        let dt = Date().timeIntervalSince(t0)
        print("CANCELAR: terminó a los \(String(format: "%.2f", dt)) s")
        XCTAssertLessThan(dt, 6, "cancelar debe responder enseguida")
    }

    func testHeavyFourKClipIsFasterThanRealTime() async throws {
        let v = try makeVideo("4k.mp4", w: 3840, h: 2160, seconds: 8) { ctx, w, h in
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        }
        var c = clip(v, e: 8)
        c.scale = [1, 1]
        let t0 = Date()
        let out = try await run(project(w: 1920, h: 1080, clips: [c]))
        let dt = Date().timeIntervalSince(t0)
        let d = try await duration(out)
        print("4K: video de \(String(format: "%.1f", d)) s guardado en \(String(format: "%.2f", dt)) s (\(String(format: "%.1f", d / dt))× tiempo real)")
        XCTAssertLessThan(dt, 8, "guardar debe tardar menos de lo que dura el video")
    }
}
