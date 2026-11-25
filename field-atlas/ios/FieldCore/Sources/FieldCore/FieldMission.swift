import Foundation

public enum TravelMode:String,Codable,CaseIterable,Identifiable {
    case walking,driving,timed
    public var id:String{rawValue}
    public var title:String{switch self{case .walking:return "Пешком";case .driving:return "На машине";case .timed:return "Замер времени"}}
    public var maximumSpeed:Double{self == .driving ? 70:8}
}
public struct RouteFix:Codable,Equatable {
    public var time:Double
    public var lat:Double
    public var lon:Double
    public var accuracy:Double
    public var speed:Double?
    public init(time:Double,lat:Double,lon:Double,accuracy:Double,speed:Double?=nil){self.time=time;self.lat=lat;self.lon=lon;self.accuracy=accuracy;self.speed=speed}
    public var valid:Bool{time.isFinite && lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) && accuracy.isFinite && accuracy>=0 && (speed == nil || speed!.isFinite && speed!>=0)}
    public func distance(to other:RouteFix)->Double{
        let r=Double.pi/180,a=sin((other.lat-lat)*r/2),b=sin((other.lon-lon)*r/2)
        let h=min(1,max(0,a*a+cos(lat*r)*cos(other.lat*r)*b*b))
        return 6371008.8*2*atan2(sqrt(h),sqrt(1-h))
    }
}
public struct MissionEvent:Codable,Equatable {
    public var kind:String
    public var time:Double
    public var fix:RouteFix?
    public var text:String?
    public init(_ kind:String,time:Double,fix:RouteFix?=nil,text:String?=nil){self.kind=kind;self.time=time;self.fix=fix;self.text=text}
}
public struct FieldMission:Codable,Identifiable,Equatable {
    public var schema="field-mission-v1"
    public var id=UUID().uuidString
    public var projectId:String
    public var title:String
    public var mode:TravelMode
    public var assignmentReference:String
    public var events:[MissionEvent]=[]
    public init(projectId:String,title:String,mode:TravelMode,assignmentReference:String=""){
        self.projectId=projectId;self.title=title;self.mode=mode;self.assignmentReference=assignmentReference
    }
    public func summary(at now:Double)->MissionSummary{MissionSummary(mission:self,now:now)}
    public var gpx:String{
        func escape(_ s:String)->String{s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        let formatter=ISO8601DateFormatter()
        let tracks=summary(at:events.last?.time ?? 0).segments.map{segment in
            "<trkseg>"+segment.map{p in "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><time>\(formatter.string(from:Date(timeIntervalSince1970:p.time)))</time></trkpt>"}.joined()+"</trkseg>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Field Atlas\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(escape(title))</name>\(tracks)</trk></gpx>"
    }
}
public struct MissionSummary:Equatable {
    public var status="planned"
    public var elapsed:Double=0
    public var recording:Double=0
    public var moving:Double=0
    public var distance:Double=0
    public var maxSpeed:Double=0
    public var rejectedFixes=0
    public var gaps=0
    public var segments:[[RouteFix]]=[]
    public var checkpoints:[MissionEvent]=[]
    public var averageMovingSpeed:Double?{moving>0 ? distance/moving:nil}
    private var started:Double?,active:Double?,ended:Double?
    private var lastTime = -Double.infinity
    private var previous:RouteFix?
    private var breakNext=true
    private var accumulated:Double=0
    public init(mission:FieldMission,now:Double){
        for event in mission.events{apply(event,mode:mission.mode)}
        updateTime(now)
    }
    public mutating func updateTime(_ now:Double){
        if let start=started{elapsed=max(0,(ended ?? max(lastTime,now))-start)}
        recording=accumulated
        if let begin=active{recording+=max(0,max(lastTime,now)-begin)}
    }
    public mutating func apply(_ e:MissionEvent,mode:TravelMode){
            guard e.time.isFinite,e.time>=lastTime,status != "completed" else{return};lastTime=e.time
            switch e.kind{
            case "start","resume":
                guard status != "running" else{return};if started == nil{started=e.time};active=e.time;status="running";previous=nil;breakNext=true
            case "pause","interrupt","finish":
                if let begin=active{accumulated+=max(0,e.time-begin)};active=nil;previous=nil;breakNext=true
                status=e.kind=="finish" ? "completed":e.kind=="interrupt" ? "interrupted":"paused"
                if e.kind=="finish"{ended=e.time}
            case "gap":
                guard status=="running" else{return};if !breakNext{gaps+=1};breakNext=true;previous=nil
            case "checkpoint":checkpoints.append(e)
            case "fix":
                guard status=="running",let p=e.fix,p.valid,abs(p.time-e.time)<=10,p.accuracy<=(mode == .driving ? 30:15) else{rejectedFixes+=1;breakNext=true;previous=nil;return}
                if let prev=previous{
                    let dt=p.time-prev.time,d=p.distance(to:prev)
                    guard dt>0 else{rejectedFixes+=1;return}
                    if dt>15{gaps+=1;breakNext=true}
                    else if d/dt>mode.maximumSpeed{rejectedFixes+=1;gaps+=1;breakNext=true;previous=nil;return}
                    else{
                        // GPS speed is preferred; an unavailable speed requires displacement above the noise floor.
                        let speed=p.speed ?? d/dt
                        let moves=p.speed != nil ? speed>(mode == .driving ? 1:0.6):d>max(2,(p.accuracy+prev.accuracy)/2)
                        if moves{distance+=d;moving+=dt;maxSpeed=max(maxSpeed,min(speed,mode.maximumSpeed))}
                    }
                }
                if breakNext || segments.isEmpty{segments.append([]);breakNext=false}
                segments[segments.count-1].append(p);previous=p
            default:break
            }
        updateTime(e.time)
    }
}
