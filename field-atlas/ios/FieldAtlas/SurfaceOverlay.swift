import ARKit
import RoomPlan
import SceneKit
import SwiftUI
import FieldCore

@MainActor final class SurfaceOverlay {
    let root=SCNNode()
    private var meshes:[UUID:SCNNode]=[:]
    private var lastMeshTime:TimeInterval=0
    private var cursor=0
    func reset(){root.childNodes.forEach{$0.removeFromParentNode()};meshes=[:];lastMeshTime=0;cursor=0}
    private func material(_ color:UIColor,lines:Bool)->SCNMaterial {
        let m=SCNMaterial();m.lightingModel = .constant;m.diffuse.contents=color
        m.isDoubleSided=true;m.fillMode=lines ? .lines:.fill;m.writesToDepthBuffer = !lines
        return m
    }
    /// Real reconstructed triangles only; no artificial room-sized coverage fill.
    func updateMeshes(_ frame:ARFrame){
        guard frame.timestamp-lastMeshTime>0.35 else{return};lastMeshTime=frame.timestamp
        let camera=frame.camera.transform.columns.3
        let anchors=frame.anchors.compactMap{$0 as? ARMeshAnchor}.filter{simd_distance($0.transform.columns.3,camera)<9}.sorted{simd_distance($0.transform.columns.3,camera)<simd_distance($1.transform.columns.3,camera)}.prefix(96)
        let ids=Set(anchors.map(\.identifier))
        for id in Array(meshes.keys) where !ids.contains(id){meshes.removeValue(forKey:id)?.removeFromParentNode()}
        let items=Array(anchors);guard !items.isEmpty else{return}
        for n in 0..<min(items.count,12){
            let anchor=items[(cursor+n)%items.count],g=anchor.geometry,v=g.vertices,f=g.faces
            guard v.count>0,v.count<100000,f.count>0,f.count<200000,f.indexCountPerPrimitive==3 else{continue}
            let vertexData=Data(bytes:v.buffer.contents(),count:v.offset+v.stride*v.count)
            let source=SCNGeometrySource(data:vertexData,semantic:.vertex,vectorCount:v.count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:4,dataOffset:v.offset,dataStride:v.stride)
            let indices=Data(bytes:f.buffer.contents(),count:f.count*f.indexCountPerPrimitive*f.bytesPerIndex)
            let element=SCNGeometryElement(data:indices,primitiveType:.triangles,primitiveCount:f.count,bytesPerIndex:f.bytesPerIndex)
            let geometry=SCNGeometry(sources:[source],elements:[element]);geometry.materials=[material(UIColor.systemGreen.withAlphaComponent(0.85),lines:true)]
            let node=meshes[anchor.identifier] ?? SCNNode();node.geometry=geometry;node.simdTransform=anchor.transform
            if meshes[anchor.identifier]==nil{meshes[anchor.identifier]=node;root.addChildNode(node)}
        }
        cursor=(cursor+12)%items.count
    }
    func showRoom(_ room:CapturedRoom){
        reset()
        let openings=room.doors+room.windows+room.openings
        for surface in room.walls {
            // Curved walls keep RoomPlan's own display; a flat hatch would be misleading.
            guard surface.curve==nil else{continue}
            let w=Double(surface.dimensions.x),h=Double(surface.dimensions.y)
            guard w>0,h>0 else{continue}
            let outline=surface.polygonCorners.count>=3 ? surface.polygonCorners.map{[Double($0.x),Double($0.y)]} : [[-w/2,-h/2],[w/2,-h/2],[w/2,h/2],[-w/2,h/2]]
            let inverse=simd_inverse(surface.transform)
            let holes=openings.filter{$0.parentIdentifier==surface.identifier}.map{opening -> [[Double]] in
                let x=opening.dimensions.x/2,y=opening.dimensions.y/2
                return [SIMD4<Float>(-x,-y,0,1),SIMD4<Float>(x,-y,0,1),SIMD4<Float>(x,y,0,1),SIMD4<Float>(-x,y,0,1)].map{p in let q=inverse*opening.transform*p;return [Double(q.x),Double(q.y)]}
            }
            var lines=SurfaceHatching.segments(outline:outline,holes:holes)
            for polygon in [outline]+holes {for i in polygon.indices{lines.append([polygon[i],polygon[(i+1)%polygon.count]])}}
            let vertices=lines.flatMap{$0.map{SCNVector3(Float($0[0]),Float($0[1]),0.008)}}
            guard !vertices.isEmpty else{continue}
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:(0..<vertices.count).map{UInt32($0)},primitiveType:.line)])
            let color:UIColor;switch surface.confidence{case .high:color = .systemGreen;default:color = .systemOrange}
            geometry.materials=[material(color,lines:false)]
            let node=SCNNode(geometry:geometry);node.simdTransform=surface.transform;root.addChildNode(node)
        }
    }
}

/// Transparent overlay shares RoomPlan's camera, without replacing its ARSession delegate.
@MainActor final class RoomSurfaceView:SCNView {
    let surfaces=SurfaceOverlay()
    private let cameraNode=SCNNode()
    weak var session:ARSession?
    private var ticker:CADisplayLink?
    override init(frame:CGRect,options:[String:Any]?=nil){super.init(frame:frame,options:options);setup()}
    required init?(coder:NSCoder){super.init(coder:coder);setup()}
    private func setup(){
        backgroundColor = .clear;isOpaque=false;isUserInteractionEnabled=false
        scene=SCNScene();scene?.rootNode.addChildNode(surfaces.root)
        cameraNode.camera=SCNCamera();scene?.rootNode.addChildNode(cameraNode);pointOfView=cameraNode
        antialiasingMode = .multisampling4X;preferredFramesPerSecond=30
    }
    override func didMoveToWindow(){super.didMoveToWindow();ticker?.invalidate();ticker=nil
        if window != nil {let link=CADisplayLink(target:self,selector:#selector(updateCamera));link.preferredFrameRateRange=CAFrameRateRange(minimum:15,maximum:30,preferred:30);link.add(to:.main,forMode:.common);ticker=link}
    }
    @objc private func updateCamera(){
        guard let frame=session?.currentFrame,bounds.width>0,bounds.height>0 else{return}
        let orientation=window?.windowScene?.interfaceOrientation ?? .portrait
        cameraNode.transform=SCNMatrix4(simd_inverse(frame.camera.viewMatrix(for:orientation)))
        cameraNode.camera?.projectionTransform=SCNMatrix4(frame.camera.projectionMatrix(for:orientation,viewportSize:bounds.size,zNear:0.05,zFar:30))
        setNeedsDisplay()
    }
    func stop(){ticker?.invalidate();ticker=nil}
}

struct RoomSurfaceCamera:UIViewRepresentable {
    let controller:InteriorCaptureController
    func makeUIView(context:Context)->RoomSurfaceView{controller.surfaceView.session=controller.view.captureSession.arSession;return controller.surfaceView}
    func updateUIView(_ view:RoomSurfaceView,context:Context){}
    static func dismantleUIView(_ uiView:RoomSurfaceView,coordinator:()){uiView.stop()}
}
