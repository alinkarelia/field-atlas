import SwiftUI
import SceneKit
import FieldCore

private struct SavedCloud:UIViewRepresentable {
    let points:[[Double]]
    func makeUIView(context:Context)->SCNView{
        let view=SCNView();view.backgroundColor=UIColor(red:0.06,green:0.12,blue:0.1,alpha:1)
        view.allowsCameraControl=true;view.autoenablesDefaultLighting=false;view.antialiasingMode = .multisampling4X
        let scene=SCNScene();view.scene=scene
        let vertices=points.map{SCNVector3(Float($0[0]),Float($0[2]),Float($0[1]))}
        if !vertices.isEmpty{
            let element=SCNGeometryElement(indices:(0..<vertices.count).map{UInt32($0)},primitiveType:.point)
            element.pointSize=6;element.minimumPointScreenSpaceRadius=1;element.maximumPointScreenSpaceRadius=4
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[element])
            let material=SCNMaterial();material.lightingModel = .constant;material.diffuse.contents=UIColor.systemGreen
            geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
            let xs=vertices.map(\.x),ys=vertices.map(\.y),zs=vertices.map(\.z)
            let center=SCNVector3((xs.min()!+xs.max()!)/2,(ys.min()!+ys.max()!)/2,(zs.min()!+zs.max()!)/2)
            let radius=max(2,max(xs.max()!-xs.min()!,max(ys.max()!-ys.min()!,zs.max()!-zs.min()!)))
            let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zFar=Double(max(100,radius*8))
            camera.position=SCNVector3(center.x+radius,center.y+radius*0.7,center.z+radius*1.4);camera.look(at:center)
            scene.rootNode.addChildNode(camera);view.pointOfView=camera
            view.defaultCameraController.target=center
        }
        return view
    }
    func updateUIView(_ view:SCNView,context:Context){}
}
struct ScanReviewScreen:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) private var dismiss
    let project:FieldProject
    @State private var frameID=""
    @State private var preview:[[Double]]=[]
    @State private var loading=false
    @State private var loadID=UUID()
    private var scans:[ScanReference]{store.state.scans.filter{$0.projectId==project.id}}
    private var groups:[String]{Array(Set(scans.map(\.frameId))).sorted{a,b in (scans.filter{$0.frameId==a}.map(\.createdAt).max() ?? 0) > (scans.filter{$0.frameId==b}.map(\.createdAt).max() ?? 0)}}
    private var selected:[ScanReference]{scans.filter{$0.frameId==frameID}}
    private func label(_ id:String)->String{
        let date=Date(timeIntervalSince1970:scans.first(where:{$0.frameId==id})?.createdAt ?? 0)
        return date.formatted(date:.abbreviated,time:.shortened)+" · \(scans.filter{$0.frameId==id}.count) частей"
    }
    var body:some View{
        NavigationStack{
            VStack(spacing:0){
                if groups.isEmpty{ContentUnavailableView("Съёмок пока нет",systemImage:"viewfinder",description:Text("Сохранённые части LiDAR появятся здесь. Карточки доступны в разделе «Объекты»."))}
                else{
                    if groups.count>1{Picker("Съёмка",selection:$frameID){ForEach(groups,id:\.self){id in Text(label(id)).tag(id)}}.pickerStyle(.menu).padding(.horizontal)}
                    ZStack{
                        Color(red:0.06,green:0.12,blue:0.1)
                        if loading{ProgressView("Открываем съёмку").tint(.white).foregroundStyle(.white)}
                        else if preview.isEmpty{Text("Не удалось открыть точки. Исходные файлы остаются на устройстве.").foregroundStyle(.white).padding()}
                        else{SavedCloud(points:preview).id(loadID).accessibilityIdentifier("saved-scan-view")}
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    VStack(alignment:.leading,spacing:8){
                        Text("\(selected.count) частей · \(selected.reduce(0){$0+$1.pointCount}) измерений").font(.headline)
                        Text("Одним пальцем — повернуть. Двумя — приблизить или переместить.").font(.caption)
                        Text("Показан облегчённый обзор. Отдельные съёмки не совмещаются без проверенной привязки.").font(.caption).foregroundStyle(.secondary)
                        if project.synthetic{Text("Тестовые измерения").font(.caption).foregroundStyle(.orange)}
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.navigationTitle("Снятые участки").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button("Готово"){dismiss()}}}
                .onAppear{frameID=groups.first ?? "";load()}
                .onChange(of:frameID){_,_ in load()}
        }
    }
    private func load(){
        guard !frameID.isEmpty else{return}
        let request=UUID();loadID=request;loading=true
        let paths=selected.compactMap{store.assetURL($0.assetId)}
        Task{
            let points=await Task.detached(priority:.userInitiated){
                var result=SurfacePreview()
                for path in paths{
                    guard let data=try? Data(contentsOf:path),let chunk=try? JSONDecoder().decode(ScanChunk.self,from:data) else{continue}
                    result.add(chunk.points)
                }
                return result.points
            }.value
            guard loadID==request else{return};preview=points;loading=false
        }
    }
}

