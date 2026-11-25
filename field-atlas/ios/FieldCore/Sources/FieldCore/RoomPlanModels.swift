import Foundation

public struct PlanWall:Codable,Equatable,Identifiable {
    public var id:String;public var code:String;public var start:[Double];public var end:[Double];public var height:Double;public var base:Double;public var confidence:Int;public var curved:Bool;public var profile:[[Double]]?
    public init(id:String,code:String,start:[Double],end:[Double],height:Double,base:Double,confidence:Int,curved:Bool=false,profile:[[Double]]?=nil){self.id=id;self.code=code;self.start=start;self.end=end;self.height=height;self.base=base;self.confidence=confidence;self.curved=curved;self.profile=profile}
    public var length:Double{hypot(end[0]-start[0],end[1]-start[1])}
    enum CodingKeys:String,CodingKey{case id,code,start,end,height,base,confidence,curved,profile}
    public init(from decoder:Decoder)throws{
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);code=try c.decodeIfPresent(String.self,forKey:.code) ?? id
        start=try c.decode([Double].self,forKey:.start);end=try c.decode([Double].self,forKey:.end)
        height=try c.decode(Double.self,forKey:.height);base=try c.decode(Double.self,forKey:.base);confidence=try c.decode(Int.self,forKey:.confidence)
        curved=try c.decodeIfPresent(Bool.self,forKey:.curved) ?? false;profile=try c.decodeIfPresent([[Double]].self,forKey:.profile)
        guard start.count==2,end.count==2,start.allSatisfy(\.isFinite),end.allSatisfy(\.isFinite),length>=0.05,height.isFinite,height>0 else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid wall dimensions"))}
    }
}
public struct PlanOpening:Codable,Equatable,Identifiable {
    public var id:String;public var code:String;public var kind:String;public var wallId:String;public var offset:Double;public var width:Double;public var height:Double;public var sill:Double
    public init(id:String,code:String,kind:String,wallId:String,offset:Double,width:Double,height:Double,sill:Double){self.id=id;self.code=code;self.kind=kind;self.wallId=wallId;self.offset=offset;self.width=width;self.height=height;self.sill=sill}
    enum CodingKeys:String,CodingKey{case id,code,kind,wallId,offset,width,height,sill}
    public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(String.self,forKey:.id);code=try c.decodeIfPresent(String.self,forKey:.code) ?? id;kind=try c.decode(String.self,forKey:.kind);wallId=try c.decode(String.self,forKey:.wallId);offset=try c.decode(Double.self,forKey:.offset);width=try c.decode(Double.self,forKey:.width);height=try c.decode(Double.self,forKey:.height);sill=try c.decode(Double.self,forKey:.sill)}
}
public struct MeasuredRoom:Codable,Equatable,Identifiable {
    public var id:String;public var name:String;public var level:Int;public var walls:[PlanWall];public var openings:[PlanOpening];public var floor:[[Double]]?;public var ceilingHeight:Double?;public var ceilingSource:String?;public var notes:[String];public var ceiling:CeilingMeasurement?;public var ceilingSourceId:String?;public var ceilingSourceHistory:[String]?
    public init(id:String,name:String,level:Int,walls:[PlanWall],openings:[PlanOpening],floor:[[Double]]?,notes:[String]=[]){self.id=id;self.name=name;self.level=level;self.walls=walls;self.openings=openings;self.floor=floor;self.notes=notes}
    enum CodingKeys:String,CodingKey{case id,name,level,walls,openings,floor,ceilingHeight,ceilingSource,notes,ceiling,ceilingSourceId,ceilingSourceHistory}
    public init(from decoder:Decoder)throws{
        let c=try decoder.container(keyedBy:CodingKeys.self);id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name);level=try c.decodeIfPresent(Int.self,forKey:.level) ?? 0
        walls=try c.decode([PlanWall].self,forKey:.walls);openings=try c.decode([PlanOpening].self,forKey:.openings);floor=try c.decodeIfPresent([[Double]].self,forKey:.floor)
        ceilingHeight=try c.decodeIfPresent(Double.self,forKey:.ceilingHeight);ceilingSource=try c.decodeIfPresent(String.self,forKey:.ceilingSource);notes=try c.decodeIfPresent([String].self,forKey:.notes) ?? []
        ceiling=try c.decodeIfPresent(CeilingMeasurement.self,forKey:.ceiling);ceilingSourceId=try c.decodeIfPresent(String.self,forKey:.ceilingSourceId);ceilingSourceHistory=try c.decodeIfPresent([String].self,forKey:.ceilingSourceHistory)
        guard !walls.isEmpty,floor == nil || floor!.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid room geometry"))}
    }
}
public struct RoomPlanDocument:Codable,Equatable {
    public var schema="field-room-plan-v1";public var frameId:String;public var synthetic=false;public var rooms:[MeasuredRoom]
    public init(frameId:String,rooms:[MeasuredRoom]){self.frameId=frameId;self.rooms=rooms}
    enum CodingKeys:String,CodingKey{case schema,frameId,synthetic,rooms}
    public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);schema=try c.decode(String.self,forKey:.schema);frameId=try c.decode(String.self,forKey:.frameId);synthetic=try c.decodeIfPresent(Bool.self,forKey:.synthetic) ?? false;rooms=try c.decode([MeasuredRoom].self,forKey:.rooms);guard schema=="field-room-plan-v1",!rooms.isEmpty else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid room plan"))}}
}
