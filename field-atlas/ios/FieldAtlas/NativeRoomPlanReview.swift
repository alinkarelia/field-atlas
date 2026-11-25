import SwiftUI
import FieldCore

struct NativeRoomPlanReview:View {
    @State private var document:RoomPlanDocument
    var onLevelChange:((String,Int)throws->Void)?
    var onCeilingStart:(()->Void)?
    var project:FieldProject?
    var onCeilingChange:((String,CeilingMeasurement)throws->MeasuredRoom)?
    @State private var ceilingRoomId:String?
    @State private var showCeiling=false
    @State private var saveError:String?
    init(document:RoomPlanDocument,onLevelChange:((String,Int)throws->Void)?=nil,project:FieldProject?=nil,onCeilingStart:(()->Void)?=nil,onCeilingChange:((String,CeilingMeasurement)throws->MeasuredRoom)?=nil){_document=State(initialValue:document);self.onLevelChange=onLevelChange;self.project=project;self.onCeilingStart=onCeilingStart;self.onCeilingChange=onCeilingChange}
    @Environment(\.dismiss) var dismiss
    @State private var index=0
    @State private var wallId:String?
    @State private var viewMode="plan"
    private var room:MeasuredRoom{document.rooms[index]}
    private var wall:PlanWall?{room.walls.first(where:{$0.id==wallId}) ?? room.walls.first}
    private var floorRoom:MeasuredRoom{
        let rooms=document.rooms.filter{$0.level==room.level}
        let walls=rooms.enumerated().flatMap{i,r in r.walls.map{w -> PlanWall in var copy=w;copy.id=r.id+"::"+w.id;copy.code="\(i+1)/\(w.code)";return copy}}
        let openings=rooms.flatMap{r in r.openings.map{o -> PlanOpening in var copy=o;copy.id=r.id+"::"+o.id;copy.wallId=r.id+"::"+o.wallId;return copy}}
        return MeasuredRoom(id:"floor",name:"Этаж",level:room.level,walls:walls,openings:openings,floor:nil)
    }
    var body:some View{
        NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){
            Picker("Комната",selection:$index){ForEach(document.rooms.indices,id:\.self){i in Text(document.rooms[i].name).tag(i)}}.pickerStyle(.menu)
            if let onLevelChange{Stepper("Этаж \(room.level)",value:Binding(get:{room.level},set:{level in do{try onLevelChange(room.id,level);document.rooms[index].level=level}catch{saveError=error.localizedDescription}}),in:-20...200)}else{Text("Этаж \(room.level)").font(.footnote)}
            Picker("Вид",selection:$viewMode){Text("Комната").tag("plan");Text("Стена").tag("elevation");Text("Этаж").tag("floor")}.pickerStyle(.segmented)
            if let wall{RoomPlanDrawing(room:viewMode=="floor" ? floorRoom:room,wall:viewMode=="floor" ? (floorRoom.walls.first(where:{$0.id==room.id+"::"+wall.id}) ?? wall):wall,elevation:viewMode=="elevation").frame(height:320).background(Color(red:0.99,green:0.985,blue:0.96),in:RoundedRectangle(cornerRadius:16))}
            Text("С — стена · Д — дверь · О — окно · П — проход").font(.caption).foregroundStyle(.secondary)
            Text("Выберите стену: её линия будет выделена, а размеры и проёмы появятся ниже.").font(.footnote)
            ScrollView(.horizontal){HStack{ForEach(room.walls){w in Button(w.code){wallId=w.id}.buttonStyle(.bordered).tint(w.id==wall?.id ? .orange:Palette.green)}}}
            if let wall{
                GroupBox(wall.code){VStack(spacing:12){LabeledContent("Длина стены",value:String(format:"%.2f м",wall.length));LabeledContent(wall.profile == nil ? "Высота стены":"Габаритная высота",value:String(format:"%.2f м",wall.height));Text(wall.confidence==2 ? "Высокое качество распознавания":"Размер требует контрольного промера").font(.caption).foregroundStyle(.secondary);if wall.curved{Text("Криволинейная стена. Сверьте форму с исходной 3D-моделью.").font(.caption).foregroundStyle(.orange)}}}
                ForEach(room.openings.filter{$0.wallId==wall.id}){opening in GroupBox("\(opening.code) · \(opening.kind=="window" ? "Окно":opening.kind=="door" ? "Дверь":"Проход")"){VStack(spacing:10){LabeledContent("Ширина",value:String(format:"%.2f м",opening.width));LabeledContent("Высота",value:String(format:"%.2f м",opening.height));LabeledContent("Низ от основания стены",value:String(format:"%.2f м",opening.sill));LabeledContent("Привязано к стене",value:wall.code)}}}
            }
            if let floor=room.floor{LabeledContent("Площадь контура пола",value:String(format:"%.2f м²",Geometry.area(floor)))}
            if let ceiling=room.ceiling,ceiling.valid{
                GroupBox("Отдельный замер потолка"){VStack(alignment:.leading,spacing:10){
                    Text(String(format:"Высота над выбранной точкой пола: %.2f–%.2f м",ceiling.heights.min()!,ceiling.heights.max()!))
                    Text(room.ceilingSource ?? "Источник требует проверки").font(.caption)
                    Text("Собственная система координат. Контур не совмещён с планом комнаты.").font(.caption).foregroundStyle(.secondary)
                    if ceiling.method=="plane-proposal"{Text("Выпуклый контур может закрывать проёмы. Это оценка поверхности.").font(.caption).foregroundStyle(.orange)}
                }}
            }else{Text("Потолок отдельно не измерен. Высота стены не подтверждает форму и отметку потолка.").font(.footnote).foregroundStyle(.secondary)}
            if project != nil && onCeilingChange != nil{Button("Измерить потолок отдельно"){onCeilingStart?();ceilingRoomId=room.id;showCeiling=true}.buttonStyle(.borderedProminent)}
            ForEach(room.notes,id:\.self){Text($0).font(.footnote).foregroundStyle(.orange)}
        }.padding(20)}.navigationTitle("План и размеры").toolbar{Button("Готово"){dismiss()}}}.fullScreenCover(isPresented:$showCeiling){if let project,let onCeilingChange,let id=ceilingRoomId{CapturePreparationScreen(project:project,onCeiling:{value in let changed=try onCeilingChange(id,value);if let i=document.rooms.firstIndex(where:{$0.id==id}){document.rooms[i]=changed}})}}.alert("Изменение не сохранено",isPresented:Binding(get:{saveError != nil},set:{if !$0{saveError=nil}})){Button("Понятно"){saveError=nil}}message:{Text(saveError ?? "")}
    }
}
private struct RoomPlanDrawing:View {
    let room:MeasuredRoom;let wall:PlanWall;let elevation:Bool
    var body:some View{Canvas{context,size in
        if elevation{
            let scale=min((size.width-80)/max(wall.length,0.1),(size.height-72)/max(wall.height,0.1)),origin=CGPoint(x:40,y:size.height-36)
            let rectangle=CGRect(x:origin.x,y:origin.y-wall.height*scale,width:wall.length*scale,height:wall.height*scale)
            let profile=wall.profile ?? [[0,0],[wall.length,0],[wall.length,wall.height],[0,wall.height]]
            var outline=Path();outline.addLines(profile.map{CGPoint(x:origin.x+$0[0]*scale,y:origin.y-$0[1]*scale)});outline.closeSubpath()
            context.fill(outline,with:.color(.green.opacity(0.08)));context.stroke(outline,with:.color(Palette.green),lineWidth:3)
            for opening in room.openings where opening.wallId==wall.id{let r=CGRect(x:origin.x+opening.offset*scale,y:origin.y-(opening.sill+opening.height)*scale,width:opening.width*scale,height:opening.height*scale);context.fill(Path(r),with:.color(opening.kind=="window" ? .blue.opacity(0.15):.white));context.stroke(Path(r),with:.color(.blue),lineWidth:1);context.draw(Text(opening.code).font(.caption),at:CGPoint(x:r.midX,y:r.midY))}
            context.draw(Text("\(wall.code) · \(wall.length,specifier:"%.2f") м").font(.caption),at:CGPoint(x:rectangle.midX,y:20));context.draw(Text("Основание стены").font(.caption2),at:CGPoint(x:rectangle.midX,y:size.height-14))
        }else{
            let points=room.walls.flatMap{[$0.start,$0.end]};guard !points.isEmpty else{return}
            let minX=points.map{$0[0]}.min()!,maxX=points.map{$0[0]}.max()!,minY=points.map{$0[1]}.min()!,maxY=points.map{$0[1]}.max()!
            let scale=min((size.width-72)/max(maxX-minX,1),(size.height-72)/max(maxY-minY,1))
            func xy(_ p:[Double])->CGPoint{CGPoint(x:36+(p[0]-minX)*scale,y:36+(maxY-p[1])*scale)}
            if let floor=room.floor{var p=Path();p.addLines(floor.map(xy));p.closeSubpath();context.fill(p,with:.color(.green.opacity(0.07)))}
            for w in room.walls{let a=xy(w.start),b=xy(w.end);var p=Path();p.move(to:a);p.addLine(to:b);context.stroke(p,with:.color(w.id==wall.id ? .orange:Palette.green),style:StrokeStyle(lineWidth:5,dash:w.curved ? [6,4]:[]));context.draw(Text(w.code).font(.caption.weight(.semibold)),at:CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2-12))}
            for opening in room.openings{guard let w=room.walls.first(where:{$0.id==opening.wallId}) else{continue};let dx=(w.end[0]-w.start[0])/w.length,dy=(w.end[1]-w.start[1])/w.length;let a=xy([w.start[0]+dx*opening.offset,w.start[1]+dy*opening.offset]),b=xy([w.start[0]+dx*(opening.offset+opening.width),w.start[1]+dy*(opening.offset+opening.width)]);var p=Path();p.move(to:a);p.addLine(to:b);context.stroke(p,with:.color(.white),lineWidth:8);context.stroke(p,with:.color(opening.kind=="window" ? .blue:.orange),style:StrokeStyle(lineWidth:2,dash:opening.kind=="opening" ? [3,3]:[]));context.draw(Text(opening.code).font(.caption2),at:CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2+12))}
        }
    }.accessibilityLabel(elevation ? "Развёртка выбранной стены. Все размеры доступны в списке ниже.":"План комнаты. Стены и проёмы подписаны; выберите стену из списка.")}
}
