import AppKit
import QuartzCore

// MARK: - Portal visuals
//
// A portal end is a small vortex on the tile's top-right corner, tinted with
// the far board's color. It spins while either agent works (or just after a
// message), opens with a pop, flares when a message passes, and collapses
// when the portal closes. Looping motion follows Live wires; one-shot motion
// follows Animations. Without motion, only colors change.

/// The vortex ring on a tile's corner.
final class PortalRingLayer: CALayer {
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let vortex = CAGradientLayer()
    private let vortexMask = CAShapeLayer()
    private let swirl = CAReplicatorLayer()
    private let arc = CAShapeLayer()
    private let core = CAShapeLayer()
    private let countDot = CAShapeLayer()
    private let countText = CATextLayer()
    private var color: NSColor = Theme.blue
    private var radius: CGFloat = 13
    private var zoom: CGFloat = 1
    private(set) var spinning = false

    override init() {
        super.init()
        setup()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        masksToBounds = false
        for l in [halo, vortex, swirl, core, ring, countDot] as [CALayer] { addSublayer(l) }
        countDot.addSublayer(countText)
        vortex.type = .conic
        vortex.startPoint = CGPoint(x: 0.5, y: 0.5)
        vortex.endPoint = CGPoint(x: 0.5, y: 0)
        vortexMask.fillRule = .evenOdd
        vortex.mask = vortexMask
        halo.fillColor = nil
        ring.fillColor = nil
        ring.lineCap = .round
        arc.fillColor = nil
        arc.lineCap = .round
        swirl.addSublayer(arc)
        swirl.instanceCount = 3
        swirl.instanceTransform = CATransform3DMakeRotation(2 * .pi / 3, 0, 0, 1)
        countText.alignmentMode = .center
        countText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        countDot.isHidden = true
        shadowOffset = .zero
    }

    /// Colors, count badge and whether the vortex turns.
    func configure(color: NSColor, count: Int, spinning: Bool) {
        self.color = color
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let cg = color.cgColor
        ring.strokeColor = cg
        halo.strokeColor = color.withAlphaComponent(0.28).cgColor
        vortex.colors = [cg, color.withAlphaComponent(0.08).cgColor, cg, color.withAlphaComponent(0.08).cgColor, cg]
        arc.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        core.fillColor = NSColor.black.withAlphaComponent(0.62).cgColor
        shadowColor = cg
        shadowOpacity = 0.6
        countDot.fillColor = cg
        countDot.isHidden = count < 2
        countText.string = count > 9 ? "9+" : "\(count)"
        countText.foregroundColor = NSColor.white.cgColor
        CATransaction.commit()
        setSpinning(spinning)
    }

    /// Places the ring with its center at `center` (in the superlayer).
    func place(center: CGPoint, zoom: CGFloat) {
        self.zoom = zoom
        let r = max(7, 13 * zoom)
        radius = r
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        position = center
        let b = bounds, c = CGPoint(x: r, y: r)
        for l in [halo, ring, vortex, vortexMask, swirl, arc, core] as [CALayer] { l.frame = b }
        halo.path = CGPath(ellipseIn: b.insetBy(dx: -3 * zoom, dy: -3 * zoom), transform: nil)
        halo.lineWidth = 3 * zoom
        ring.path = CGPath(ellipseIn: b.insetBy(dx: 1, dy: 1), transform: nil)
        ring.lineWidth = max(1.5, 2.5 * zoom)
        let m = CGMutablePath()
        m.addEllipse(in: b.insetBy(dx: r * 0.08, dy: r * 0.08))
        m.addEllipse(in: CGRect(x: c.x - r * 0.36, y: c.y - r * 0.36, width: r * 0.72, height: r * 0.72))
        vortexMask.path = m
        let a = CGMutablePath()
        a.addArc(center: c, radius: r * 0.6, startAngle: 0, endAngle: .pi * 0.62, clockwise: false)
        arc.path = a
        arc.lineWidth = max(1, 1.6 * zoom)
        core.path = CGPath(ellipseIn: CGRect(x: c.x - r * 0.34, y: c.y - r * 0.34, width: r * 0.68, height: r * 0.68), transform: nil)
        shadowRadius = 6 * zoom
        shadowPath = CGPath(ellipseIn: b, transform: nil)
        let d = max(11, 13 * zoom)
        countDot.frame = CGRect(x: b.maxX - d * 0.55, y: b.minY - d * 0.45, width: d, height: d)
        countDot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        countText.fontSize = d * 0.68
        countText.font = NSFont.systemFont(ofSize: d * 0.68, weight: .bold)
        countText.frame = CGRect(x: 0, y: (d - d * 0.86) / 2, width: d, height: d * 0.86)
        CATransaction.commit()
    }

    private func setSpinning(_ on: Bool) {
        let on = on && Prefs.shared.wiresOn
        guard on != spinning else { return }
        spinning = on
        if on {
            vortex.add(Self.spin(2.4, reverse: false), forKey: "spin")
            swirl.add(Self.spin(3.6, reverse: true), forKey: "spin")
        } else {
            vortex.removeAnimation(forKey: "spin")
            swirl.removeAnimation(forKey: "spin")
        }
    }

    private static func spin(_ d: CFTimeInterval, reverse: Bool) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = (reverse ? 1 : -1) * 2 * Double.pi
        a.duration = d
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        return a
    }

    private func flare(peak: CGFloat = 22, duration: CFTimeInterval = 0.35) {
        let f = CAKeyframeAnimation(keyPath: "shadowRadius")
        f.values = [6 * zoom, peak * zoom, 6 * zoom]
        f.duration = duration
        f.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let o = CAKeyframeAnimation(keyPath: "shadowOpacity")
        o.values = [0.6, 1, 0.6]
        o.duration = duration
        add(f, forKey: "flare")
        add(o, forKey: "flareOpacity")
    }

    /// The portal just opened: it pops in and swirls fast for a moment.
    func opened() {
        opacity = 1
        guard Prefs.shared.motion else { return }
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = [0.1, 1.25, 0.94, 1]
        s.keyTimes = [0, 0.55, 0.8, 1]
        s.duration = 0.42
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 0; o.toValue = 1; o.duration = 0.2
        add(s, forKey: "open")
        add(o, forKey: "openFade")
        // A fast turn that settles to the normal spin.
        let burst = CABasicAnimation(keyPath: "transform.rotation.z")
        burst.fromValue = 0; burst.toValue = -4 * Double.pi
        burst.duration = 0.7
        burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        swirl.add(burst, forKey: "burst")
        flare(peak: 26, duration: 0.6)
    }

    /// Something came out of the other side (an arrival or a jump).
    func burst() {
        guard Prefs.shared.motion else { return }
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = [1, 1.55, 1]
        s.duration = 0.4
        s.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(s, forKey: "burst")
        flare(peak: 26, duration: 0.5)
    }

    /// A message passed through.
    func pulse() {
        guard Prefs.shared.motion else { return }
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = [1, 1.22, 1]
        s.duration = 0.3
        add(s, forKey: "pulse")
        flare()
    }

    func collapse(completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        if Prefs.shared.motion {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1; s.toValue = 0.05; s.duration = 0.3
            s.timingFunction = CAMediaTimingFunction(name: .easeIn)
            add(s, forKey: "collapse")
        }
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 1; o.toValue = 0; o.duration = Prefs.shared.motion ? 0.3 : 0.2
        add(o, forKey: "collapseFade")
        opacity = 0
        CATransaction.commit()
    }
}

/// A spark that travels along a short arc (header → ring, or ring → header).
enum PortalSpark {
    static func fly(in host: CALayer, from a: CGPoint, to b: CGPoint, color: NSColor, zoom: CGFloat, delay: CFTimeInterval = 0) {
        guard Prefs.shared.motion else { return }
        let d = max(4, 6 * zoom)
        let s = CAShapeLayer()
        s.path = CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil)
        s.fillColor = NSColor.white.cgColor
        s.shadowColor = color.cgColor
        s.shadowOpacity = 1
        s.shadowRadius = 6 * zoom
        s.shadowOffset = .zero
        s.zPosition = 11
        s.position = b
        s.opacity = 0
        host.addSublayer(s)
        let path = CGMutablePath()
        path.move(to: a)
        let lift = min(abs(b.x - a.x) * 0.3, 40 * zoom)
        path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.8, 1]
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = 0.32
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { s.removeFromSuperlayer() }
        s.add(g, forKey: "fly")
        CATransaction.commit()
    }
}

/// The iris above the tiles when jumping through a portal: it grows out of
/// the ring on departure and closes into the ring on arrival.
enum PortalIris {
    private static let key = "pitwall.portal.iris"

    static func clear(_ view: NSView) {
        view.layer?.sublayers?.filter { $0.name == key }.forEach { $0.removeFromSuperlayer() }
    }

    /// `opening`: from the ring out to cover the canvas; else the reverse.
    static func play(in view: NSView, at p: CGPoint, color: NSColor, zoom: CGFloat, opening: Bool, duration: CFTimeInterval) {
        clear(view)
        guard Prefs.shared.motion, let host = view.layer else { return }
        let diag = hypot(view.bounds.width, view.bounds.height) * 1.1
        let small = max(7, 13 * zoom)
        let l = CAShapeLayer()
        l.name = key
        l.frame = view.bounds
        func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), transform: nil) }
        let grad = CAGradientLayer()
        grad.type = .radial
        grad.frame = view.bounds
        grad.startPoint = CGPoint(x: p.x / max(view.bounds.width, 1), y: p.y / max(view.bounds.height, 1))
        let reach = diag / max(view.bounds.width, 1)
        grad.endPoint = CGPoint(x: grad.startPoint.x + reach, y: grad.startPoint.y + reach * view.bounds.width / max(view.bounds.height, 1))
        grad.colors = [NSColor.black.withAlphaComponent(0.9).cgColor, color.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0.5).cgColor]
        grad.locations = [0, 0.08, 1]
        l.fillColor = NSColor.white.cgColor
        grad.mask = l
        grad.name = key
        let from = opening ? circle(small) : circle(diag)
        let to = opening ? circle(diag) : circle(small)
        l.path = to
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = from; a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: opening ? .easeIn : .easeOut)
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = opening ? 0 : 0.85
        o.toValue = opening ? 0.85 : 0
        o.duration = duration
        grad.opacity = Float(opening ? 0.85 : 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { if !opening { grad.removeFromSuperlayer() } }
        l.add(a, forKey: "iris")
        grad.add(o, forKey: "fade")
        host.addSublayer(grad)
        CATransaction.commit()
        // A departure iris that nothing replaces fades away on its own.
        if opening {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6) { [weak grad] in grad?.removeFromSuperlayer() }
        }
    }
}
