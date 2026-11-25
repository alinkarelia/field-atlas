import Foundation

/// Metres in the local survey frame; screen coordinates are supplied by the view.
public struct PlanViewport: Equatable {
    public var centerX: Double = 0
    public var centerY: Double = 0
    public private(set) var scale: Double = 5
    public init() {}
    public func world(x: Double, y: Double, width: Double, height: Double) -> [Double] {
        [centerX + (x-width/2)/scale, centerY - (y-height/2)/scale]
    }
    public func screen(_ point: [Double], width: Double, height: Double) -> [Double] {
        [width/2+(point[0]-centerX)*scale, height/2-(point[1]-centerY)*scale]
    }
    public mutating func pan(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        centerX -= x/scale; centerY += y/scale
    }
    public mutating func zoom(_ factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        scale = min(200, max(0.01, scale*factor))
    }
    public mutating func fit(_ points: [[Double]], width: Double, height: Double) {
        let valid=points.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }
        guard width > 0, height > 0,
              let minX=valid.map({$0[0]}).min(), let maxX=valid.map({$0[0]}).max(),
              let minY=valid.map({$0[1]}).min(), let maxY=valid.map({$0[1]}).max() else { return }
        centerX=(minX+maxX)/2; centerY=(minY+maxY)/2
        scale=min(200,max(0.01,min(width/max(10,maxX-minX),height/max(10,maxY-minY))))
    }
}
