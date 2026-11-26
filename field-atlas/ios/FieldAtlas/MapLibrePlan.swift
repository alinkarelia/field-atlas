import SwiftUI
import MapLibre
import CoreLocation
import FieldCore

struct MapLibrePlan:UIViewRepresentable {
    var records:[Observation];var origin:GeoOrigin?
    var catalog:TerritoryCatalog?=nil;var mapURL:URL?=nil
    var track:[[[Double]]]=[];var currentPosition:[Double]?=nil
    var centerRequest=UUID();var zoomRequest=0;var fitRequest=UUID()
    var selectedPlace:TerritoryPlace?=nil
    var placing=false
    var onPick:(([Double])->Void)?=nil;var onSite:((TerritoryPlace)->Void)?=nil
    var onRecord:((String)->Void)?=nil
    var onScale:((String)->Void)?=nil
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeUIView(context:Context)->MLNMapView {
        let map=SurveyMapView(frame:.zero,styleURL:Bundle.main.url(forResource:"map-style",withExtension:"json"))
        map.delegate=context.coordinator;map.accessibilityIdentifier="survey-map"
        map.onLayout={ [weak coordinator=context.coordinator] map in coordinator?.fitInitial(map) }
        map.logoView.isHidden=true;map.attributionButton.isHidden=true
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView=false
        tap.delegate=context.coordinator
        for gesture in map.gestureRecognizers ?? [] {if let existing=gesture as? UITapGestureRecognizer,existing.numberOfTapsRequired==2{tap.require(toFail:existing)}}
        map.addGestureRecognizer(tap)
        context.coordinator.map=map
        return map
    }
    func updateUIView(_ map:MLNMapView,context:Context){
        let c=context.coordinator,old=c.parent;c.parent=self
        if old.mapURL != mapURL{c.installBase(map)}
        c.fitInitial(map)
        if old.fitRequest != fitRequest{c.fit(map)}
        if old.zoomRequest != zoomRequest{map.setZoomLevel(map.zoomLevel+Double(zoomRequest-old.zoomRequest),animated:false)}
        if old.centerRequest != centerRequest,let p=currentPosition,let coordinate=SurveyGeography.coordinate(p,origin:origin){map.setCenter(coordinate,zoomLevel:max(map.zoomLevel,17),animated:false)}
        if old.origin==nil,currentPosition != nil,let origin{map.setCenter(CLLocationCoordinate2D(latitude:origin.lat,longitude:origin.lon),zoomLevel:17,animated:false)}
        if old.selectedPlace?.id != selectedPlace?.id,let p=selectedPlace?.point{map.setCenter(CLLocationCoordinate2D(latitude:p[0],longitude:p[1]),zoomLevel:16,animated:false)}
        c.refresh(map)
    }
    final class Coordinator:NSObject,MLNMapViewDelegate,UIGestureRecognizerDelegate {
        var parent:MapLibrePlan;weak var map:MLNMapView?
        var towns:[(String,CLLocationCoordinate2D)]=[]
        var initializedCamera=false
        init(_ parent:MapLibrePlan){self.parent=parent}
        @objc func tap(_ gesture:UITapGestureRecognizer){
            guard gesture.state == .ended,let map else{return}
            let point=gesture.location(in:map)
            // Annotation selection has its own action; do not simultaneously place a field point.
            if !parent.placing,let hit=map.hitTest(point,with:nil),hit is MLNAnnotationView || hit.superview is MLNAnnotationView{return}
            let coordinate=map.convert(point,toCoordinateFrom:map)
            if CLLocationCoordinate2DIsValid(coordinate){parent.onPick?([coordinate.latitude,coordinate.longitude])}
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool {
            parent.placing && gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer
        }
        func fitInitial(_ map:MLNMapView){
            guard !initializedCamera,map.bounds.width>1,map.bounds.height>1,map.style != nil,parent.catalog != nil || parent.origin != nil else{return}
            initializedCamera=true;fit(map)
        }
        func fit(_ map:MLNMapView){
            let coordinates=parent.records.flatMap{record in ([record.point].compactMap{$0}+record.points+record.segments.flatMap{$0}).compactMap{SurveyGeography.coordinate($0,origin:record.origin)}} + parent.track.flatMap{$0}.compactMap{SurveyGeography.coordinate($0,origin:parent.origin)}
            if let first=coordinates.first {
                let latitudes=coordinates.map(\.latitude),longitudes=coordinates.map(\.longitude)
                let sw=CLLocationCoordinate2D(latitude:latitudes.min()!,longitude:longitudes.min()!),ne=CLLocationCoordinate2D(latitude:latitudes.max()!,longitude:longitudes.max()!)
                if abs(sw.latitude-ne.latitude)+abs(sw.longitude-ne.longitude)<0.00001{map.setCenter(first,zoomLevel:18,animated:false)}
                else{map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw:sw,ne:ne),edgePadding:UIEdgeInsets(top:150,left:50,bottom:260,right:65),animated:false)}
            }
            else if let origin=parent.origin{map.setCenter(CLLocationCoordinate2D(latitude:origin.lat,longitude:origin.lon),zoomLevel:17,animated:false)}
            else if let b=parent.catalog?.bounds,b.count==2 {map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw:CLLocationCoordinate2D(latitude:b[0][0],longitude:b[0][1]),ne:CLLocationCoordinate2D(latitude:b[1][0],longitude:b[1][1])),edgePadding:UIEdgeInsets(top:110,left:30,bottom:240,right:30),animated:false)}
            else{map.setCenter(CLLocationCoordinate2D(latitude:61.02,longitude:36.74),zoomLevel:8,animated:false)}
        }
        func mapView(_ mapView:MLNMapView,didFinishLoading style:MLNStyle){installBase(mapView);fitInitial(mapView);refresh(mapView)}
        func installBase(_ map:MLNMapView){
            guard let style=map.style,let url=parent.mapURL else{return}
            for name in ["boundary","water","green","road","building"]{if let layer=style.layer(withIdentifier:"territory-"+name){style.removeLayer(layer)}}
            if let source=style.source(withIdentifier:"territory"){style.removeSource(source)}
            let source=MLNShapeSource(identifier:"territory",url:url,options:nil);style.addSource(source)
            for (kind,color) in [("boundary",UIColor(red:0.9,green:0.93,blue:0.87,alpha:1)),("water",UIColor(red:0.67,green:0.82,blue:0.85,alpha:1)),("green",UIColor(red:0.75,green:0.82,blue:0.7,alpha:1)),("building",UIColor(red:0.76,green:0.71,blue:0.63,alpha:1))]{
                let layer=MLNFillStyleLayer(identifier:"territory-"+kind,source:source)
                layer.predicate=NSPredicate(format:"layer == %@",kind);layer.fillColor=NSExpression(forConstantValue:color)
                if kind=="building"{layer.minimumZoomLevel=13};style.addLayer(layer)
            }
            let road=MLNLineStyleLayer(identifier:"territory-road",source:source);road.predicate=NSPredicate(format:"layer == %@","road")
            road.lineColor=NSExpression(forConstantValue:UIColor(red:0.68,green:0.58,blue:0.43,alpha:1));road.lineWidth=NSExpression(forConstantValue:1.4);style.addLayer(road)
            towns=[]
            if let data=try? Data(contentsOf:url),let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let features=json["features"] as? [[String:Any]]{
                for f in features{guard let p=f["properties"] as? [String:Any],p["layer"] as? String=="settlement",let name=p["name"] as? String,let geometry=f["geometry"] as? [String:Any],let point=geometry["coordinates"] as? [Double],point.count==2 else{continue};towns.append((name,CLLocationCoordinate2D(latitude:point[1],longitude:point[0])))}
            }
        }
        func mapView(_ mapView:MLNMapView,regionDidChangeAnimated animated:Bool){refresh(mapView)}
        func refresh(_ map:MLNMapView){
            guard map.style != nil else{return}
            if let existing=map.annotations{map.removeAnnotations(existing)}
            for record in parent.records {
                guard let recordOrigin=record.origin else{continue}
                func coordinate(_ point:[Double])->CLLocationCoordinate2D?{SurveyGeography.coordinate(point,origin:recordOrigin)}
                if let point=record.point,let location=coordinate(point){let a=TerritoryAnnotation();a.coordinate=location;a.title=record.title.isEmpty ? "Полевой объект":record.title;a.kind="field";a.recordID=record.id;map.addAnnotation(a)}
                for part in (record.kind=="boundary" || record.segments.isEmpty ? [record.points]:record.segments) where part.count>=2 {
                    var coords=part.compactMap(coordinate);guard coords.count==part.count else{continue}
                    if record.kind=="boundary"{map.addAnnotation(MLNPolygon(coordinates:&coords,count:UInt(coords.count)))}
                    else{map.addAnnotation(MLNPolyline(coordinates:&coords,count:UInt(coords.count)))}
                }
            }
            for part in parent.track where part.count>=2{var coordinates=part.compactMap{SurveyGeography.coordinate($0,origin:parent.origin)};if coordinates.count==part.count{map.addAnnotation(MLNPolyline(coordinates:&coordinates,count:UInt(coordinates.count)))}}
            if let p=parent.currentPosition,let c=SurveyGeography.coordinate(p,origin:parent.origin){let a=TerritoryAnnotation();a.kind="gps";a.coordinate=c;a.title="Моё положение";map.addAnnotation(a)}
            let important:Set<String>=["Вытегра","Ошта","Анненский Мост","Саминский Погост","Янишево"]
            for (name,coordinate) in towns where map.zoomLevel>=11 || important.contains(name){
                let point=map.convert(coordinate,toPointTo:map);guard map.bounds.insetBy(dx:-80,dy:-30).contains(point)else{continue}
                let a=TerritoryAnnotation();a.kind="town";a.coordinate=coordinate;a.title=name;map.addAnnotation(a)
            }
            if map.zoomLevel>=12 {
                for p in parent.catalog?.places ?? []{guard let point=p.point else{continue};let coordinate=CLLocationCoordinate2D(latitude:point[0],longitude:point[1]);guard map.bounds.contains(map.convert(coordinate,toPointTo:map))else{continue};let a=TerritoryAnnotation();a.coordinate=coordinate;a.title=p.name;a.siteID=p.id;a.kind="site";map.addAnnotation(a)}
            }
            guard initializedCamera else{return}
            let meters=map.metersPerPoint(atLatitude:map.centerCoordinate.latitude)*100
            let label=meters>=1000 ? String(format:"100 пт ≈ %.1f км",meters/1000):String(format:"100 пт ≈ %.0f м",meters)
            DispatchQueue.main.async{[weak self] in self?.parent.onScale?(label)}
        }
        func mapView(_ mapView:MLNMapView,viewFor annotation:MLNAnnotation)->MLNAnnotationView? {
            guard let item=annotation as? TerritoryAnnotation else{return nil}
            let view=MLNAnnotationView(reuseIdentifier:nil),label=UILabel()
            if item.kind=="town"{label.text=item.title;label.font = .systemFont(ofSize:11,weight:.semibold);label.textColor = .darkGray;label.backgroundColor=UIColor.white.withAlphaComponent(0.78);label.sizeToFit();view.frame=CGRect(x:0,y:0,width:label.bounds.width+8,height:22);label.frame=view.bounds.insetBy(dx:4,dy:2);view.isUserInteractionEnabled=false}
            else{view.frame=CGRect(x:0,y:0,width:32,height:32);view.backgroundColor=item.kind=="gps" ? .systemBlue:item.kind=="field" ? .systemOrange:UIColor(red:0.16,green:0.35,blue:0.28,alpha:1);view.layer.cornerRadius=16;view.layer.borderColor=UIColor.white.cgColor;view.layer.borderWidth=2;label.text=item.kind=="gps" ? "●":item.kind=="field" ? "+":"•";label.textColor = .white;label.textAlignment = .center;label.frame=view.bounds}
            view.addSubview(label);view.isAccessibilityElement=item.kind != "town";view.accessibilityLabel=item.title;return view
        }
        func mapView(_ mapView:MLNMapView,didSelect annotation:MLNAnnotation){
            guard !parent.placing,let item=annotation as? TerritoryAnnotation else{return}
            if let id=item.siteID,let p=parent.catalog?.places.first(where:{$0.id==id}){parent.onSite?(p)}
            else if let id=item.recordID{parent.onRecord?(id)}
        }
        func mapView(_ mapView:MLNMapView,strokeColorForShapeAnnotation annotation:MLNShape)->UIColor{UIColor(red:0.05,green:0.4,blue:0.28,alpha:1)}
        func mapView(_ mapView:MLNMapView,lineWidthForPolylineAnnotation annotation:MLNPolyline)->CGFloat{4}
        func mapView(_ mapView:MLNMapView,fillColorForPolygonAnnotation annotation:MLNPolygon)->UIColor{UIColor(red:0.25,green:0.5,blue:0.3,alpha:0.22)}
    }
}
final class SurveyMapView:MLNMapView {
    var onLayout:((MLNMapView)->Void)?
    override func layoutSubviews(){super.layoutSubviews();onLayout?(self)}
}
final class TerritoryAnnotation:MLNPointAnnotation {var kind="site";var siteID:String?;var recordID:String?}

enum SurveyGeography {
    static func coordinate(_ point:[Double],origin:GeoOrigin?)->CLLocationCoordinate2D? {
        guard let origin,point.count==2,point.allSatisfy(\.isFinite),origin.lat.isFinite,origin.lon.isFinite,abs(origin.lat)<89.9,abs(origin.lon)<=180 else{return nil}
        let value=CLLocationCoordinate2D(latitude:origin.lat+point[1]/111320,longitude:origin.lon+point[0]/(111320*cos(origin.lat * .pi/180)))
        return CLLocationCoordinate2DIsValid(value) ? value:nil
    }
}

