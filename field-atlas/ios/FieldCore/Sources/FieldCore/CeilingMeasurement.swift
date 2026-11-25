import Foundation

public struct CeilingMeasurement:Codable,Equatable {
    public var schema="field-ceiling-v1"
    public var frameId:String?
    public var method:String
    public var floorPoint:[Double]?
    public var points:[[Double]]?
    public var manualHeight:Double?
    public var source:String?
    public var reviewed=true
    public var createdAt=Date().timeIntervalSince1970*1000
    public init(frameId:String,method:String,floorPoint:[Double],points:[[Double]]){self.frameId=frameId;self.method=method;self.floorPoint=floorPoint;self.points=points}
    enum CodingKeys:String,CodingKey{case schema,frameId,method,floorPoint,points,manualHeight,source,reviewed,createdAt}
    public init(from decoder:Decoder)throws{
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schema=try c.decode(String.self,forKey:.schema);method=try c.decode(String.self,forKey:.method);reviewed=try c.decode(Bool.self,forKey:.reviewed)
        frameId=try c.decodeIfPresent(String.self,forKey:.frameId);floorPoint=try c.decodeIfPresent([Double].self,forKey:.floorPoint);points=try c.decodeIfPresent([[Double]].self,forKey:.points)
        manualHeight=try c.decodeIfPresent(Double.self,forKey:.manualHeight);source=try c.decodeIfPresent(String.self,forKey:.source);createdAt=try c.decodeIfPresent(Double.self,forKey:.createdAt) ?? 0
    }
    public var heights:[Double]{if method=="manual-height",let manualHeight{return [manualHeight]};guard let floorPoint,floorPoint.count==3 else{return []};return (points ?? []).filter{$0.count==3}.map{$0[2]-floorPoint[2]}}
    public var meanHeight:Double?{let h=heights;return h.isEmpty ? nil:h.reduce(0,+)/Double(h.count)}
    public var valid:Bool{
        guard schema=="field-ceiling-v1",reviewed else{return false}
        if method=="manual-height"{return manualHeight.map{$0.isFinite && $0>=0.5 && $0<=30}==true && (source?.trimmingCharacters(in:.whitespacesAndNewlines).count ?? 0)>=3 && (source?.count ?? 0)<=500}
        guard ["manual-corners","plane-proposal"].contains(method),let frameId,!frameId.isEmpty,frameId.count<=200,let floorPoint,floorPoint.count==3,floorPoint.allSatisfy({$0.isFinite && abs($0)<100000}),let points,(3...500).contains(points.count),points.allSatisfy({$0.count==3 && $0.allSatisfy({$0.isFinite && abs($0)<100000})}),heights.allSatisfy({$0>=0.5 && $0<=30}) else{return false}
        return Geometry.validPolygon(points.map{[$0[0],$0[1]]})
    }
}
