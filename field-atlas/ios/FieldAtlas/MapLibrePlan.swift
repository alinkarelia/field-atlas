import SwiftUI
import MapLibre
import CoreLocation
import FieldCore

/// Geographic overview uses project geometry, without silently downloading a third-party basemap.
struct MapLibrePlan:UIViewRepresentable {
    var records:[Observation];var origin:GeoOrigin
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeUIView(context:Context)->MLNMapView {
        let map=MLNMapView(frame:.zero);map.delegate=context.coordinator
        map.styleURL=Bundle.main.url(forResource:"map-style",withExtension:"json")
        map.setCenter(CLLocationCoordinate2D(latitude:origin.lat,longitude:origin.lon),zoomLevel:18,animated:false)
        return map
    }
    func updateUIView(_ map:MLNMapView,context:Context){context.coordinator.records=records;context.coordinator.origin=origin;context.coordinator.refresh(map)}
    final class Coordinator:NSObject,MLNMapViewDelegate {
        var records:[Observation]=[];var origin=GeoOrigin(lat:0,lon:0)
        func mapView(_ mapView:MLNMapView,didFinishLoading style:MLNStyle){refresh(mapView)}
        func refresh(_ map:MLNMapView){
            guard map.style != nil else{return}
            if let existing=map.annotations{map.removeAnnotations(existing)}
            func coordinate(_ point:[Double])->CLLocationCoordinate2D{CLLocationCoordinate2D(latitude:origin.lat+point[1]/111320,longitude:origin.lon+point[0]/(111320*cos(origin.lat * .pi/180)))}
            for record in records {
                if let point=record.point,point.count==2{let a=MLNPointAnnotation();a.coordinate=coordinate(point);a.title=record.title;map.addAnnotation(a)}
                if record.points.count>=2 {
                    for part in (record.kind=="boundary" || record.segments.isEmpty ? [record.points]:record.segments) where part.count>=2{
                    var coords=part.map(coordinate)
                    if record.kind=="boundary"{let shape=MLNPolygon(coordinates:&coords,count:UInt(coords.count));map.addAnnotation(shape)}
                    else{let line=MLNPolyline(coordinates:&coords,count:UInt(coords.count));map.addAnnotation(line)}}
                }
            }
        }
        func mapView(_ mapView:MLNMapView,strokeColorForShapeAnnotation annotation:MLNShape)->UIColor{UIColor(red:0.13,green:0.31,blue:0.24,alpha:1)}
        func mapView(_ mapView:MLNMapView,fillColorForPolygonAnnotation annotation:MLNPolygon)->UIColor{UIColor(red:0.3,green:0.5,blue:0.3,alpha:0.16)}
    }
}
