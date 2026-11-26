import SwiftUI
import FieldCore

struct LocalPlan: View {
    var records: [Observation]
    var track: [[[Double]]] = []
    var currentPosition:[Double]?=nil
    var centerRequest=UUID()
    var onPick: ([Double]) -> Void
    @State private var viewport=PlanViewport()
    @GestureState private var translation=CGSize.zero
    @GestureState private var magnification: CGFloat=1

    private var surveyPoints: [[Double]] {
        records.flatMap { $0.points + ($0.point.map { [$0] } ?? []) } + track.flatMap { $0 }
    }
    private var effective: PlanViewport {
        var result=viewport
        result.zoom(Double(magnification))
        result.pan(x:translation.width,y:translation.height)
        return result
    }
    private func gridStep(_ scale: Double) -> Double {
        let base=pow(10,floor(log10(40/scale)))
        return [1.0,2,5,10].first(where:{$0*base*scale >= 40})! * base
    }
    var body: some View {
        GeometryReader { proxy in
            let view=effective
            let step=gridStep(view.scale)
            ZStack(alignment:.topLeading) {
                Canvas { context,size in draw(&context,size:size,view:view,step:step) }
                    .contentShape(Rectangle())
                    .accessibilityLabel("План участка")
                    .accessibilityIdentifier("survey-map")
                    .gesture(DragGesture(minimumDistance:6)
                        .updating($translation) { value,state,_ in state=value.translation }
                        .onEnded { value in viewport.pan(x:value.translation.width,y:value.translation.height) })
                    .simultaneousGesture(MagnifyGesture()
                        .updating($magnification) { value,state,_ in state=value.magnification }
                        .onEnded { value in viewport.zoom(Double(value.magnification)) })
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        onPick(view.world(x:value.location.x,y:value.location.y,width:proxy.size.width,height:proxy.size.height))
                    })
                VStack(alignment:.leading,spacing:6) {
                    HStack(spacing:0) {
                        control("Уменьшить","minus","map-zoom-out") { viewport.zoom(0.5) }
                        control("Увеличить","plus","map-zoom-in") { viewport.zoom(2) }
                        control("Показать всё","arrow.up.left.and.arrow.down.right","map-fit") { fit(proxy.size) }
                    }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    Text("Клетка: \(step.formatted(.number.precision(.fractionLength(0...2)))) м")
                        .font(.caption2).padding(6).background(.regularMaterial,in:RoundedRectangle(cornerRadius:6))
                        .accessibilityIdentifier("map-scale")
                }.padding(.leading,16).padding(.top,132)
            }.onAppear { fit(proxy.size) }
            .onChange(of:centerRequest){_,_ in if let currentPosition{viewport.fit([currentPosition],width:proxy.size.width,height:proxy.size.height)}}
            .onChange(of:currentPosition){old,new in if old==nil,let new{viewport.fit([new],width:proxy.size.width,height:proxy.size.height)}}
        }
    }
    private func fit(_ size: CGSize) {
        if surveyPoints.isEmpty { viewport=PlanViewport() }
        else { viewport.fit(surveyPoints,width:max(80,size.width-80),height:max(80,size.height-320)) }
    }
    private func control(_ label:String,_ symbol:String,_ id:String,action:@escaping()->Void)->some View {
        Button(action:action) { Image(systemName:symbol).frame(width:48,height:48) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private func draw(_ context: inout GraphicsContext,size:CGSize,view:PlanViewport,step:Double) {
        context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(red:0.91,green:0.93,blue:0.89)))
        func point(_ value:[Double])->CGPoint {
            let p=view.screen(value,width:size.width,height:size.height)
            return CGPoint(x:p[0],y:p[1])
        }
        let low=view.world(x:0,y:size.height,width:size.width,height:size.height)
        let high=view.world(x:size.width,y:0,width:size.width,height:size.height)
        var grid=Path()
        for x in stride(from:floor(low[0]/step)*step,through:high[0],by:step) {
            grid.move(to:point([x,low[1]]));grid.addLine(to:point([x,high[1]]))
        }
        for y in stride(from:floor(low[1]/step)*step,through:high[1],by:step) {
            grid.move(to:point([low[0],y]));grid.addLine(to:point([high[0],y]))
        }
        context.stroke(grid,with:.color(.green.opacity(0.08)),lineWidth:1)
        if let position=currentPosition,position.count==2{
            let p=point(position),dot=Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14))
            context.fill(dot,with:.color(.blue));context.stroke(dot,with:.color(.white),lineWidth:3)
        }
        for record in records {
            if record.points.count>1 {
                let parts=record.kind=="boundary" || record.segments.isEmpty ? [record.points]:record.segments
                for vertices in parts {
                    var path=Path();path.addLines(vertices.filter{$0.count>=2}.map(point))
                    if record.kind=="boundary" { path.closeSubpath();context.fill(path,with:.color(.green.opacity(0.05))) }
                    context.stroke(path,with:.color(record.needsReview ? .orange:record.kind=="boundary" ? Palette.green.opacity(0.6):.white),style:StrokeStyle(lineWidth:record.kind=="road" ? 10:2,lineCap:.round,dash:record.kind=="boundary" ? [5,4]:[]))
                }
            }
            if let value=record.point,value.count==2 {
                let q=point(value),rect=CGRect(x:q.x-6,y:q.y-9,width:12,height:18)
                let path=Path(ellipseIn:rect.insetBy(dx:-7,dy:-4))
                context.fill(path,with:.color(.white))
                context.stroke(path,with:.color(record.kind=="anomaly" ? .orange:Palette.green),lineWidth:1.5)
                let icon=Image(systemName:SurveyFeature(rawValue:record.kind)?.symbol ?? "rectangle.portrait.fill")
                context.draw(context.resolve(icon),in:CGRect(x:q.x-8,y:q.y-9,width:16,height:16))
            }
        }
        for segment in track where segment.count>1 {
            var path=Path();path.addLines(segment.filter{$0.count>=2}.map(point))
            context.stroke(path,with:.color(Palette.green),style:StrokeStyle(lineWidth:2,dash:[5,3]))
        }
        for value in track.flatMap({$0}) where value.count==2 {
            let p=point(value)
            context.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(Palette.green))
        }
    }
}
