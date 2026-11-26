import Foundation

/// Clips a diagonal survey hatch to the actual wall outline, excluding openings.
/// Coordinates are in metres in the surface's own XY plane.
public enum SurfaceHatching {
    /// Finite-width triangles stay visible from both sides of a wall. Input lines are already clipped.
    public static func ribbons(lines: [[[Double]]], width: Double) -> (vertices: [[Double]], indices: [UInt32]) {
        guard width.isFinite, width > 0, width <= 0.1 else { return ([],[]) }
        var vertices:[[Double]]=[]; var indices:[UInt32]=[]
        for line in lines.prefix(10000) {
            guard line.count==2, line.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{continue}
            let a=line[0], b=line[1], dx=b[0]-a[0], dy=b[1]-a[1], length=hypot(dx,dy)
            guard length>0.001 else{continue}
            let nx = -dy/length*width/2, ny=dx/length*width/2, i=UInt32(vertices.count)
            vertices += [[a[0]+nx,a[1]+ny],[a[0]-nx,a[1]-ny],[b[0]+nx,b[1]+ny],[b[0]-nx,b[1]-ny]]
            indices += [i,i+1,i+2,i+2,i+1,i+3]
        }
        return (vertices,indices)
    }
    public static func segments(outline: [[Double]], holes: [[[Double]]] = [], spacing: Double = 0.18) -> [[[Double]]] {
        guard outline.count >= 3, outline.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
              spacing.isFinite, spacing > 0 else { return [] }
        let polygons = [outline] + holes.filter { $0.count >= 3 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }
        let offsets = outline.map { $0[1] - $0[0] }
        guard let low = offsets.min(), let high = offsets.max(), high-low < 1000 else { return [] }
        let step = max(spacing, (high-low)/400)
        func inside(_ p: [Double], _ polygon: [[Double]]) -> Bool {
            var result = false
            for i in polygon.indices {
                let a=polygon[i], b=polygon[(i+1)%polygon.count]
                if (a[1]>p[1]) != (b[1]>p[1]), p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0] { result.toggle() }
            }
            return result
        }
        var result: [[[Double]]] = []
        for offset in stride(from: floor(low/step)*step, through: high, by: step) {
            var intersections: [Double] = []
            for polygon in polygons {
                for i in polygon.indices {
                    let a=polygon[i], b=polygon[(i+1)%polygon.count]
                    let da=a[1]-a[0]-offset, db=b[1]-b[0]-offset
                    guard abs(da-db)>1e-9 else { continue }
                    let t=da/(da-db)
                    if t >= 0 && t <= 1 { intersections.append(a[0]+t*(b[0]-a[0])) }
                }
            }
            intersections.sort()
            for i in intersections.indices.dropLast() {
                let a=intersections[i], b=intersections[i+1], middle=(a+b)/2
                guard b-a>0.002, inside([middle,middle+offset], outline),
                      !polygons.dropFirst().contains(where: { inside([middle,middle+offset], $0) }) else { continue }
                result.append([[a,a+offset],[b,b+offset]])
            }
        }
        return result
    }
}

/// A bounded, spatially distributed preview. It does not discard older sectors
/// just because the newest chunk contains many repeated measurements.
public struct SurfacePreview {
    private var cells: [String: [Double]] = [:]
    public private(set) var resolution: Double = 0.10
    public let limit: Int
    public init(limit: Int = 80000) { self.limit=max(32,limit) }
    public var points: [[Double]] { Array(cells.values) }
    public mutating func add(_ points: [[Double]]) {
        for p in points where p.count == 4 && p.allSatisfy(\.isFinite) && p[3] >= 1 {
            let key=p.prefix(3).map { String(floor($0/resolution)) }.joined(separator: ":")
            if cells[key] == nil || p[3] > cells[key]![3] { cells[key]=p }
        }
        while cells.count > limit {
            let previous=Array(cells.values); cells.removeAll(keepingCapacity:true); resolution *= 2
            for p in previous {
                let key=p.prefix(3).map { String(floor($0/resolution)) }.joined(separator: ":")
                if cells[key] == nil || p[3] > cells[key]![3] { cells[key]=p }
            }
        }
    }
}
