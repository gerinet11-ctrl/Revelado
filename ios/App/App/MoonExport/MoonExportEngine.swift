import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import Metal
import simd

// MARK: - Lo que manda la app web

/// Proyecto de video tal como lo prepara la app web. Todos los tiempos de clips y textos están en
/// «tiempo del proyecto» (antes de aplicar la velocidad); los de la salida se calculan aquí.
struct MoonProject: Codable {
    struct Look: Codable {
        var m: [Float]            // 12 números: 3 filas (r, g, b) con 3 pesos y un desfase (0–1)
        var shadows: Float
        var highlights: Float
        var split: Float
        var vignette: Float
        var grain: Float
        var flash: Float
    }
    struct Clip: Codable {
        var kind: String          // "video" o "still" (foto)
        var file: String
        var s: Double
        var e: Double
        var tr: String            // none, fade, black, white, slide, zoom
        var vol: Double           // 0–100
        var scale: [Float]        // cuánto del video se ve (x, y)
        var off: [Float]          // desplazamiento del encuadre (x, y)
    }
    struct Overlay: Codable {
        var file: String         // PNG transparente del tamaño del video
        var t0: Double
        var t1: Double
        var x: Float             // centro del texto (0–1)
        var y: Float
        var anim: String         // none, fade, pop, rise
    }
    struct Music: Codable { var file: String; var vol: Double; var offset: Double; var fade: Bool }
    struct Voice: Codable { var file: String; var at: Double; var dur: Double; var vol: Double }

    var width: Int
    var height: Int
    var fps: Int
    var speed: Double
    var vol: Double
    var trDur: Double
    var look: Look
    var clips: [Clip]
    var overlays: [Overlay]
    var music: Music?
    var voice: Voice?
}

/// Reloj para el registro de tiempos (solo ayuda a diagnosticar).
enum MoonClock {
    static var start = Date()
    static func t() -> String { String(format: "+%.2f s", Date().timeIntervalSince(start)) }
}

enum MoonError: LocalizedError {
    case bad(String)
    case missing(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .bad(let m): return m
        case .missing(let f): return "Falta un archivo: \(f)"
        case .cancelled: return "Guardado cancelado"
        }
    }
}

// MARK: - Plan de dibujo

final class MoonClipInfo {
    var ax = SIMD4<Float>(1, 0, 0, 0)     // de la imagen vista a la textura: x = ax.x·u + ax.y·v + ax.z
    var ay = SIMD4<Float>(0, 1, 0, 0)
    var startOut = 0.0                    // segundos de salida
    var lenOut = 0.0
    var holdLen = 0.0                     // cuánto dura la mezcla con el último fotograma del clip anterior
}

final class MoonPlan {
    let project: MoonProject
    var infos: [MoonClipInfo] = []
    var totalOut = 0.0
    var projTotal = 0.0
    var overlayTextures: [Int: MTLTexture] = [:]
    let lock = NSLock()
    init(project: MoonProject) { self.project = project }
}

final class MoonInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let plan: MoonPlan
    let index: Int
    let trackA: CMPersistentTrackID
    let trackB: CMPersistentTrackID?

    init(range: CMTimeRange, plan: MoonPlan, index: Int, trackA: CMPersistentTrackID, trackB: CMPersistentTrackID?) {
        self.timeRange = range
        self.plan = plan
        self.index = index
        self.trackA = trackA
        self.trackB = trackB
        var ids: [NSValue] = [NSNumber(value: trackA)]
        if let b = trackB { ids.append(NSNumber(value: b)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

// MARK: - Compositor (lo que dibuja cada fotograma)

final class MoonCompositor: NSObject, AVVideoCompositing {
    static var firstFrame = true
    private let queue = DispatchQueue(label: "moon.compositor")
    private static let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    var sourcePixelBufferAttributes: [String: Any]? { MoonCompositor.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { MoonCompositor.attrs }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                do {
                    guard let inst = request.videoCompositionInstruction as? MoonInstruction else { throw MoonError.bad("Instrucción desconocida") }
                    guard let out = request.renderContext.newPixelBuffer() else { throw MoonError.bad("No hay memoria para el fotograma") }
                    guard let cur = request.sourceFrame(byTrackID: inst.trackA) else { throw MoonError.bad("Falta una imagen del video") }
                    var prev: CVPixelBuffer? = nil
                    if let b = inst.trackB { prev = request.sourceFrame(byTrackID: b) }
                    let first = MoonCompositor.firstFrame
                    MoonCompositor.firstFrame = false
                    if first { print("MOONNATIVE \(MoonClock.t()) llegó el primer fotograma") }
                    try MoonRenderer.shared().render(plan: inst.plan, index: inst.index, time: request.compositionTime.seconds, cur: cur, prev: prev, out: out)
                    if first { print("MOONNATIVE \(MoonClock.t()) primer fotograma dibujado") }
                    request.finish(withComposedVideoFrame: out)
                } catch {
                    print("MOONNATIVE compositor error: \(error)")
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Gráfica (Metal)

private let moonShader = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs_main(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);
    return o;
}

struct MainU {
    float4 r0; float4 r1; float4 r2;
    float4 tone;   // sombras, luces, tonos, viñeta
    float4 fx;     // grano, flash, semilla, modo
    float4 mixv;   // k
    float4 dip;    // color y cantidad
    float4 res;    // ancho, alto
    float4 cur;    // escala (xy), desplazamiento (zw)
    float4 prv;
    float4 axc; float4 ayc; float4 axp; float4 ayp;
};

float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
float shoulder(float v) { float k = 205.0 / 255.0; float w = 50.0 / 255.0; return v <= k ? v : k + w * (1.0 - exp(-(v - k) / w)); }

float4 pick(texture2d<float> t, sampler s, float2 p, float4 sc, float4 ax, float4 ay) {
    float2 q = (p - 0.5) * sc.xy + 0.5 + sc.zw;
    if (q.x < 0.0 || q.x > 1.0 || q.y < 0.0 || q.y > 1.0) return float4(0.0);
    float2 tuv = float2(ax.x * q.x + ax.y * q.y + ax.z, ay.x * q.x + ay.y * q.y + ay.z);
    return float4(t.sample(s, tuv).rgb, 1.0);
}

fragment float4 fs_main(VOut in [[stage_in]],
                        texture2d<float> t0 [[texture(0)]],
                        texture2d<float> t1 [[texture(1)]],
                        constant MainU& U [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float mode = U.fx.w;
    float k = U.mixv.x;
    float4 s;
    if (mode < 0.5) {
        s = pick(t0, smp, uv, U.cur, U.axc, U.ayc);
    } else if (mode < 1.5) {
        s = mix(pick(t1, smp, uv, U.prv, U.axp, U.ayp), pick(t0, smp, uv, U.cur, U.axc, U.ayc), k);
    } else if (mode < 2.5) {
        float e = 1.0 - k;
        if (uv.x < e) s = pick(t1, smp, float2(uv.x + k, uv.y), U.prv, U.axp, U.ayp);
        else s = pick(t0, smp, float2(uv.x - e, uv.y), U.cur, U.axc, U.ayc);
    } else {
        s = mix(pick(t1, smp, (uv - 0.5) / (1.0 + 0.6 * k) + 0.5, U.prv, U.axp, U.ayp),
                pick(t0, smp, (uv - 0.5) * (0.72 + 0.28 * k) + 0.5, U.cur, U.axc, U.ayc),
                smoothstep(0.1, 0.9, k));
    }
    float3 c = s.rgb;
    if (s.a > 0.0) {
        c = float3(dot(U.r0.xyz, c) + U.r0.w, dot(U.r1.xyz, c) + U.r1.w, dot(U.r2.xyz, c) + U.r2.w);
        float L = clamp(luma(c), 0.0, 1.0);
        c += U.tone.x * (1.0 - L) * (1.0 - L) + U.tone.y * L * L;
        float q = U.tone.z * (1.0 - L);
        float u = U.tone.z * L;
        c += float3(-14.0 * q + 18.0 * u, 4.0 * q + 6.0 * u, 16.0 * q - 14.0 * u) / 255.0;
        c = clamp(c, 0.0, 1.0);
        float flash = U.fx.y;
        if (flash > 0.0) {
            float2 dp = (uv - float2(0.5, 0.42)) * U.res.xy;
            float tt = min(1.0, length(dp) / (max(U.res.x, U.res.y) * 0.75));
            float nearv = (1.0 - tt) * sqrt(1.0 - tt);
            float L0 = luma(c);
            float3 f = c * (1.0 + flash * (0.14 + 0.26 * nearv));
            f += flash * (34.0 / 255.0) * (1.0 - L0) * (1.0 - L0) * (0.55 + 0.45 * nearv);
            float L2 = luma(f);
            if (L2 > 0.6) { float sp = flash * (22.0 / 255.0) * (L2 - 0.6) * nearv; f += float3(sp, sp, sp * 1.06); }
            f.b += flash * (4.0 / 255.0) * nearv;
            c = float3(shoulder(f.r), shoulder(f.g), shoulder(f.b));
        }
        float vig = U.tone.w;
        if (vig > 0.0) {
            float2 d = (uv - 0.5) * 2.0;
            float t2 = clamp((length(d) / 1.4142 - 0.3) / 0.7, 0.0, 1.0);
            c *= 1.0 - vig * t2 * t2 * (3.0 - 2.0 * t2);
        }
        float grain = U.fx.x;
        if (grain > 0.0) {
            float n = fract(sin(dot(in.pos.xy + U.fx.z, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
            c += n * grain;
        }
        c = clamp(c, 0.0, 1.0) * s.a;
    }
    c = mix(c, U.dip.rgb, U.dip.a);
    return float4(c, 1.0);
}

struct TextU { float4 a; float4 c; };   // a: opacidad, escala, subida · c: centro

fragment float4 fs_text(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant TextU& U [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 p = U.c.xy + (in.uv - U.c.xy) / U.a.y - float2(0.0, U.a.z);
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return float4(0.0);
    float4 s = t.sample(smp, p);
    return float4(s.rgb * U.a.x, s.a * U.a.x);
}
"""

private struct MainUniforms {
    var r0 = SIMD4<Float>(repeating: 0)
    var r1 = SIMD4<Float>(repeating: 0)
    var r2 = SIMD4<Float>(repeating: 0)
    var tone = SIMD4<Float>(repeating: 0)
    var fx = SIMD4<Float>(repeating: 0)
    var mixv = SIMD4<Float>(repeating: 0)
    var dip = SIMD4<Float>(repeating: 0)
    var res = SIMD4<Float>(repeating: 0)
    var cur = SIMD4<Float>(repeating: 0)
    var prv = SIMD4<Float>(repeating: 0)
    var axc = SIMD4<Float>(repeating: 0)
    var ayc = SIMD4<Float>(repeating: 0)
    var axp = SIMD4<Float>(repeating: 0)
    var ayp = SIMD4<Float>(repeating: 0)
}

private struct TextUniforms {
    var a = SIMD4<Float>(repeating: 0)
    var c = SIMD4<Float>(repeating: 0)
}

final class MoonRenderer {
    private static var instance: MoonRenderer?
    private static let guardLock = NSLock()
    static func shared() throws -> MoonRenderer {
        guardLock.lock(); defer { guardLock.unlock() }
        if let r = instance { return r }
        let r = try MoonRenderer()
        instance = r
        return r
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let mainPipe: MTLRenderPipelineState
    private let textPipe: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()

    private init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { print("MOONNATIVE sin Metal"); throw MoonError.bad("Este dispositivo no permite el guardado rápido") }
        print("MOONNATIVE Metal: \(d.name)")
        device = d
        queue = q
        print("MOONNATIVE \(MoonClock.t()) compilando el programa de la gráfica")
        let lib = try d.makeLibrary(source: moonShader, options: nil)
        print("MOONNATIVE \(MoonClock.t()) programa compilado")
        func pipe(_ frag: String, blend: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vs_main")
            desc.fragmentFunction = lib.makeFunction(name: frag)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blend {
                let a = desc.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try d.makeRenderPipelineState(descriptor: desc)
        }
        mainPipe = try pipe("fs_main", blend: false)
        textPipe = try pipe("fs_text", blend: true)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, d, nil, &cache)
        print("MOONNATIVE \(MoonClock.t()) gráfica lista")
    }

    private func texture(_ pb: CVPixelBuffer, target: Bool) throws -> (MTLTexture, CVMetalTexture) {
        guard let cache = cache else { throw MoonError.bad("Sin memoria de gráficos") }
        var cv: CVMetalTexture?
        let usage: MTLTextureUsage = target ? [.shaderRead, .renderTarget] : [.shaderRead]
        let attrs = [kCVMetalTextureUsage as String: NSNumber(value: usage.rawValue)] as CFDictionary
        let st = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, attrs, .bgra8Unorm,
                                                           CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cv)
        guard st == kCVReturnSuccess, let c = cv, let t = CVMetalTextureGetTexture(c) else { throw MoonError.bad("No se pudo preparar un fotograma") }
        return (t, c)
    }

    private func overlayTexture(_ plan: MoonPlan, _ i: Int) throws -> MTLTexture {
        plan.lock.lock(); defer { plan.lock.unlock() }
        if let t = plan.overlayTextures[i] { return t }
        let url = URL(fileURLWithPath: plan.project.overlays[i].file)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw MoonError.missing(url.lastPathComponent) }
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: d) else { throw MoonError.bad("No se pudo preparar un texto") }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        plan.overlayTextures[i] = t
        return t
    }

    /// Transición en este instante: modo de mezcla (0 ninguno, 1 disolver, 2 deslizar, 3 zoom), avance y paso por color.
    static func transition(plan: MoonPlan, index i: Int, time: Double, hasPrev: Bool) -> (mode: Float, k: Float, dip: SIMD4<Float>) {
        let p = plan.project, info = plan.infos[i], c = p.clips[i]
        let dt = time - info.startOut
        let rem = info.startOut + info.lenOut - time
        let D = min(p.trDur, info.lenOut * 0.5)
        var mode: Float = 0, k: Float = 1
        var dip = SIMD4<Float>(0, 0, 0, 0)
        func col(_ id: String) -> Float { id == "white" ? 1 : 0 }
        if i > 0 && c.tr != "none" {
            if c.tr == "black" || c.tr == "white" {
                let h = D / 2
                if dt < h { let v = col(c.tr); dip = SIMD4<Float>(v, v, v, Float(1 - dt / h)) }
            } else if dt < D && hasPrev {
                let x = Float(max(0, min(1, dt / D)))
                mode = c.tr == "fade" ? 1 : c.tr == "slide" ? 2 : c.tr == "zoom" ? 3 : 0
                k = x * x * (3 - 2 * x)
            }
        }
        if i + 1 < p.clips.count {
            let nx = p.clips[i + 1], nInfo = plan.infos[i + 1]
            if nx.tr == "black" || nx.tr == "white" {
                let h = min(p.trDur, nInfo.lenOut * 0.5, info.lenOut) / 2
                if rem < h { let v = col(nx.tr); dip = SIMD4<Float>(v, v, v, Float(max(0, min(1, 1 - rem / h)))) }
            }
        }
        return (mode, k, dip)
    }

    func render(plan: MoonPlan, index i: Int, time: Double, cur: CVPixelBuffer, prev: CVPixelBuffer?, out: CVPixelBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        let p = plan.project, L = p.look, info = plan.infos[i], clip = p.clips[i]
        let (curT, curKeep) = try texture(cur, target: false)
        let (outT, outKeep) = try texture(out, target: true)
        var prevT = curT
        var prevKeep: CVMetalTexture? = nil
        if let pv = prev { let r = try texture(pv, target: false); prevT = r.0; prevKeep = r.1 }
        let tr = MoonRenderer.transition(plan: plan, index: i, time: time, hasPrev: prev != nil && i > 0)

        var u = MainUniforms()
        u.r0 = SIMD4<Float>(L.m[0], L.m[1], L.m[2], L.m[3])
        u.r1 = SIMD4<Float>(L.m[4], L.m[5], L.m[6], L.m[7])
        u.r2 = SIMD4<Float>(L.m[8], L.m[9], L.m[10], L.m[11])
        u.tone = SIMD4<Float>(L.shadows, L.highlights, L.split, L.vignette)
        let seed = Float((time * 1000).truncatingRemainder(dividingBy: 1000) / 7)
        u.fx = SIMD4<Float>(L.grain, L.flash, seed, tr.mode)
        u.mixv = SIMD4<Float>(tr.k, 0, 0, 0)
        u.dip = tr.dip
        u.res = SIMD4<Float>(Float(CVPixelBufferGetWidth(out)), Float(CVPixelBufferGetHeight(out)), 0, 0)
        u.cur = SIMD4<Float>(clip.scale[0], clip.scale[1], clip.off[0], clip.off[1])
        u.axc = info.ax; u.ayc = info.ay
        if i > 0 {
            let pc = p.clips[i - 1], pi = plan.infos[i - 1]
            u.prv = SIMD4<Float>(pc.scale[0], pc.scale[1], pc.off[0], pc.off[1])
            u.axp = pi.ax; u.ayp = pi.ay
        } else {
            u.prv = u.cur; u.axp = u.axc; u.ayp = u.ayc
        }

        guard let cb = queue.makeCommandBuffer() else { throw MoonError.bad("Sin cola de gráficos") }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outT
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { throw MoonError.bad("Sin codificador de gráficos") }
        enc.setRenderPipelineState(mainPipe)
        enc.setFragmentTexture(curT, index: 0)
        enc.setFragmentTexture(prevT, index: 1)
        withUnsafeBytes(of: &u) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Textos y stickers
        let T = time * p.speed
        enc.setRenderPipelineState(textPipe)
        for (oi, o) in p.overlays.enumerated() {
            guard T >= o.t0 - 0.02 && T < o.t1 else { continue }
            let ad = 0.35 * p.speed
            let kin = Float(max(0, min(1, (T - o.t0) / ad)))
            let kout = o.anim == "fade" ? Float(max(0, min(1, (min(o.t1, plan.projTotal) - T) / ad))) : 1
            let ease = 1 - (1 - kin) * (1 - kin)
            var alpha: Float = 1, scale: Float = 1, rise: Float = 0
            switch o.anim {
            case "fade": alpha = min(kin, kout)
            case "pop":
                alpha = min(1, kin * 2)
                scale = 0.6 + 0.4 * (ease + 0.25 * sin(kin * Float.pi))
            case "rise":
                alpha = kin
                rise = (1 - ease) * 0.06
            default: break
            }
            if alpha <= 0.001 { continue }
            let tex = try overlayTexture(plan, oi)
            var tu = TextUniforms()
            tu.a = SIMD4<Float>(alpha, scale, rise, 0)
            tu.c = SIMD4<Float>(o.x, o.y, 0, 0)
            enc.setFragmentTexture(tex, index: 0)
            withUnsafeBytes(of: &tu) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((curKeep, outKeep, prevKeep)) {}
        if cb.status == .error { throw cb.error ?? MoonError.bad("Falló la gráfica") }
    }
}

// MARK: - Exportador

final class MoonExporter {
    let project: MoonProject
    private var session: AVAssetExportSession?
    private var cancelled = false
    private let lock = NSLock()

    init(project: MoonProject) { self.project = project }

    func cancel() {
        lock.lock(); cancelled = true; let s = session; lock.unlock()
        s?.cancelExport()
    }

    private func checkCancelled() throws {
        lock.lock(); let c = cancelled; lock.unlock()
        if c { throw MoonError.cancelled }
    }

    /// Video de prueba (solo para la autoprueba en el simulador).
    static func makeTestVideo(seconds: Double) throws -> URL {
        let w = 640, h = 360, fps = 30
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("moon-prueba-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MoonError.bad("No se pudo crear el video de prueba") }
        writer.startSession(atSourceTime: .zero)
        for f in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let b = pb else { throw MoonError.bad("Sin memoria") }
            CVPixelBufferLockBaseAddress(b, [])
            if let base = CVPixelBufferGetBaseAddress(b) {
                let bpr = CVPixelBufferGetBytesPerRow(b)
                for y in 0..<h { let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self); for x in 0..<w { row[x * 4] = UInt8((f * 8) % 255); row[x * 4 + 1] = UInt8(y * 255 / h); row[x * 4 + 2] = UInt8(x * 255 / w); row[x * 4 + 3] = 255 } }
            }
            CVPixelBufferUnlockBaseAddress(b, [])
            _ = adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? MoonError.bad("No se pudo crear el video de prueba") }
        return out
    }

    /// Una foto se convierte en un video corto sin movimiento para tratarla como cualquier clip.
    static func makeStillMovie(png: URL, seconds: Double) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw MoonError.missing(png.lastPathComponent) }
        let w = max(2, img.width & ~1), h = max(2, img.height & ~1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("moon-still-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MoonError.bad("No se pudo preparar una foto") }
        writer.startSession(atSourceTime: .zero)
        func buffer() throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let b = pb else { throw MoonError.bad("Sin memoria") }
            CVPixelBufferLockBaseAddress(b, [])
            defer { CVPixelBufferUnlockBaseAddress(b, []) }
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return b
        }
        let frame = try buffer()
        func append(_ t: CMTime) throws {
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 500 { Thread.sleep(forTimeInterval: 0.01); tries += 1 }
            if !adaptor.append(frame, withPresentationTime: t) { throw writer.error ?? MoonError.bad("No se pudo preparar una foto") }
        }
        try append(.zero)
        if seconds > 0.4 { try append(CMTime(seconds: seconds - 0.2, preferredTimescale: 600)) }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? MoonError.bad("No se pudo preparar una foto") }
        return out
    }

    /// Cómo pasar de «imagen vista (u, v)» a «textura del video» según la orientación del archivo.
    static func orientation(natural: CGSize, transform t: CGAffineTransform) -> (SIMD4<Float>, SIMD4<Float>) {
        let rect = CGRect(origin: .zero, size: natural).applying(t)
        let dw = Double(abs(rect.width)), dh = Double(abs(rect.height))
        let t2 = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let inv = t2.inverted()
        let nw = Double(natural.width), nh = Double(natural.height)
        let ax = SIMD4<Float>(Float(Double(inv.a) * dw / nw), Float(Double(inv.c) * dh / nw), Float(Double(inv.tx) / nw), 0)
        let ay = SIMD4<Float>(Float(Double(inv.b) * dw / nh), Float(Double(inv.d) * dh / nh), Float(Double(inv.ty) / nh), 0)
        return (ax, ay)
    }

    func export(to url: URL, progress: @escaping (Double) -> Void) async throws {
        let p = project
        MoonClock.start = Date()
        MoonCompositor.firstFrame = true
        print("MOONNATIVE \(MoonClock.t()) empieza el montaje")
        guard !p.clips.isEmpty else { throw MoonError.bad("El proyecto no tiene clips") }
        let speed = max(0.25, p.speed)
        let fm = FileManager.default
        var temps: [URL] = []
        defer { for t in temps { try? fm.removeItem(at: t) } }

        let plan = MoonPlan(project: p)
        let comp = AVMutableComposition()
        guard let trackA = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MoonError.bad("No se pudo preparar el video") }
        let audioClips = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        // Archivos de cada clip
        struct Src { var asset: AVURLAsset; var video: AVAssetTrack; var audio: AVAssetTrack?; var ax: SIMD4<Float>; var ay: SIMD4<Float> }
        var srcs: [Int: Src] = [:]
        for (i, c) in p.clips.enumerated() {
            try checkCancelled()
            var url = URL(fileURLWithPath: c.file)
            guard fm.fileExists(atPath: url.path) else { throw MoonError.missing(url.lastPathComponent) }
            if c.kind == "still" {
                url = try MoonExporter.makeStillMovie(png: url, seconds: max(c.e, 0.5) + 0.1)
                temps.append(url)
            }
            let asset = AVURLAsset(url: url)
            let vts = try await asset.loadTracks(withMediaType: .video)
            guard let vt = vts.first else { throw MoonError.bad("«\(URL(fileURLWithPath: c.file).lastPathComponent)» no tiene video") }
            let ats = try await asset.loadTracks(withMediaType: .audio)
            let nat = try await vt.load(.naturalSize)
            let tf = try await vt.load(.preferredTransform)
            let (ax, ay) = MoonExporter.orientation(natural: nat, transform: tf)
            srcs[i] = Src(asset: asset, video: vt, audio: c.kind == "still" ? nil : ats.first, ax: ax, ay: ay)
        }

        // Línea de tiempo: los clips van seguidos; cada uno dura (fin − inicio) / velocidad
        var cursor = CMTime.zero
        var starts: [CMTime] = [], durs: [CMTime] = []
        var instr: [AVVideoCompositionInstructionProtocol] = []
        let ts: CMTimeScale = 60000
        var clipVolumes: [(CMTime, Float)] = []
        for (i, c) in p.clips.enumerated() {
            try checkCancelled()
            guard let s = srcs[i] else { continue }
            let srcLen = max(0.05, c.e - c.s)
            let outLen = CMTimeMakeWithSeconds(srcLen / speed, preferredTimescale: ts)
            let srcRange = CMTimeRange(start: CMTimeMakeWithSeconds(c.s, preferredTimescale: ts), duration: CMTimeMakeWithSeconds(srcLen, preferredTimescale: ts))
            try trackA.insertTimeRange(srcRange, of: s.video, at: cursor)
            trackA.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration), toDuration: outLen)
            if let at = s.audio, let ac = audioClips {
                try? ac.insertTimeRange(srcRange, of: at, at: cursor)
                ac.scaleTimeRange(CMTimeRange(start: cursor, duration: srcRange.duration), toDuration: outLen)
            }
            clipVolumes.append((cursor, Float(c.vol / 100 * p.vol / 100)))
            let info = MoonClipInfo()
            info.ax = s.ax; info.ay = s.ay
            info.startOut = cursor.seconds
            info.lenOut = outLen.seconds
            plan.infos.append(info)
            starts.append(cursor); durs.append(outLen)
            cursor = CMTimeAdd(cursor, outLen)
        }
        plan.totalOut = cursor.seconds
        plan.projTotal = p.clips.reduce(0) { $0 + ($1.e - $1.s) }

        // Último fotograma del clip anterior, para mezclarlo al entrar (disolver, deslizar y zoom)
        var holds: [Int: CMTime] = [:]
        for i in 1..<max(1, p.clips.count) where ["fade", "slide", "zoom"].contains(p.clips[i].tr) {
            guard let prevSrc = srcs[i - 1] else { continue }
            let pc = p.clips[i - 1]
            let hold = CMTimeMakeWithSeconds(min(p.trDur, plan.infos[i].lenOut * 0.5), preferredTimescale: ts)
            let lastLen = min(1.0 / 30.0, max(0.02, pc.e - pc.s))
            let lastRange = CMTimeRange(start: CMTimeMakeWithSeconds(pc.e - lastLen, preferredTimescale: ts), duration: CMTimeMakeWithSeconds(lastLen, preferredTimescale: ts))
            try trackB.insertTimeRange(lastRange, of: prevSrc.video, at: starts[i])
            trackB.scaleTimeRange(CMTimeRange(start: starts[i], duration: lastRange.duration), toDuration: hold)
            holds[i] = hold
        }
        for i in 0..<p.clips.count {
            if let h = holds[i], h < durs[i] {
                instr.append(MoonInstruction(range: CMTimeRange(start: starts[i], duration: h), plan: plan, index: i, trackA: trackA.trackID, trackB: trackB.trackID))
                instr.append(MoonInstruction(range: CMTimeRange(start: CMTimeAdd(starts[i], h), duration: CMTimeSubtract(durs[i], h)), plan: plan, index: i, trackA: trackA.trackID, trackB: nil))
            } else if let h = holds[i] {
                _ = h
                instr.append(MoonInstruction(range: CMTimeRange(start: starts[i], duration: durs[i]), plan: plan, index: i, trackA: trackA.trackID, trackB: trackB.trackID))
            } else {
                instr.append(MoonInstruction(range: CMTimeRange(start: starts[i], duration: durs[i]), plan: plan, index: i, trackA: trackA.trackID, trackB: nil))
            }
        }

        // Sonido: clips, música y voz
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let ac = audioClips, !ac.segments.isEmpty {
            let ip = AVMutableAudioMixInputParameters(track: ac)
            for (t, v) in clipVolumes { ip.setVolume(v, at: t) }
            mixParams.append(ip)
        } else if let ac = audioClips {
            comp.removeTrack(ac)
        }
        let total = cursor
        if let m = p.music, m.vol > 0, fm.fileExists(atPath: m.file) {
            let ma = AVURLAsset(url: URL(fileURLWithPath: m.file))
            if let mt = try await ma.loadTracks(withMediaType: .audio).first, let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let dur = try await ma.load(.duration).seconds
                let avail = dur - m.offset
                if avail > 0.05 {
                    let len = min(total.seconds, avail)
                    try tr.insertTimeRange(CMTimeRange(start: CMTimeMakeWithSeconds(m.offset, preferredTimescale: ts), duration: CMTimeMakeWithSeconds(len, preferredTimescale: ts)), of: mt, at: .zero)
                    let ip = AVMutableAudioMixInputParameters(track: tr)
                    let v = Float(m.vol / 100)
                    if m.fade && len > 0.2 {
                        let fadeLen = min(1.5, len)
                        let fs = len - fadeLen
                        ip.setVolume(v, at: .zero)
                        ip.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeMakeWithSeconds(fs, preferredTimescale: ts), duration: CMTimeMakeWithSeconds(fadeLen, preferredTimescale: ts)))
                    } else {
                        ip.setVolume(v, at: .zero)
                    }
                    mixParams.append(ip)
                }
            }
        }
        if let vo = p.voice, vo.vol > 0, fm.fileExists(atPath: vo.file) {
            let va = AVURLAsset(url: URL(fileURLWithPath: vo.file))
            let startOut = vo.at / speed
            if startOut < total.seconds - 0.05, let vt = try await va.loadTracks(withMediaType: .audio).first, let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let dur = try await va.load(.duration).seconds
                let len = min(vo.dur, dur, total.seconds - startOut)
                if len > 0.05 {
                    try tr.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMakeWithSeconds(len, preferredTimescale: ts)), of: vt, at: CMTimeMakeWithSeconds(startOut, preferredTimescale: ts))
                    let ip = AVMutableAudioMixInputParameters(track: tr)
                    ip.setVolume(Float(vo.vol / 100), at: .zero)
                    mixParams.append(ip)
                }
            }
        }

        // Composición de video
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = MoonCompositor.self
        vc.renderSize = CGSize(width: p.width, height: p.height)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, p.fps)))
        vc.instructions = instr
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2

        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams

        try checkCancelled()
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard let sess = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw MoonError.bad("Este dispositivo no puede guardar este video") }
        sess.outputURL = url
        sess.outputFileType = .mp4
        sess.videoComposition = vc
        if !mixParams.isEmpty { sess.audioMix = mix }
        sess.audioTimePitchAlgorithm = .spectral
        lock.lock(); session = sess; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw MoonError.cancelled }

        // Vigilante: si en 45 s no hay ningún avance, se corta con un aviso en vez de quedarse colgado.
        final class Watch { var stalled = false }
        let watch = Watch()
        print("MOONNATIVE \(MoonClock.t()) sesión lista: \(p.clips.count) clip(s), \(String(format: "%.2f", plan.totalOut)) s, \(p.width)x\(p.height)")
        let poll = Task {
            var lastValue = -1.0
            var ticks = 0
            var lastChange = Date()
            while !Task.isCancelled {
                let v = Double(sess.progress)
                progress(v)
                ticks += 1
                if ticks % 10 == 0 { print("MOONNATIVE \(MoonClock.t()) progreso \(String(format: "%.2f", v)) estado \(sess.status.rawValue)") }
                if v != lastValue { lastValue = v; lastChange = Date() }
                else if Date().timeIntervalSince(lastChange) > 90 { watch.stalled = true; sess.cancelExport(); break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sess.exportAsynchronously { c.resume() }
        }
        poll.cancel()
        print("MOONNATIVE \(MoonClock.t()) sesión terminó: estado \(sess.status.rawValue) error \(String(describing: sess.error))")
        switch sess.status {
        case .completed:
            progress(1)
        case .cancelled:
            if watch.stalled { throw MoonError.bad("El guardado se detuvo: sin avances durante 90 segundos") }
            throw MoonError.cancelled
        default:
            throw sess.error ?? MoonError.bad("No se pudo guardar el video")
        }
    }
}
