import Foundation

/// Relative pressure height is a hint only. A proposal never changes the confirmed floor.
public struct FloorSuggestion {
    public private(set) var level:Int
    public private(set) var proposal:Int?
    private var baseline:Double?
    private var latest:Double?
    private var samples:[(height:Double,time:Double)]=[]
    public init(level:Int=1){self.level=level}
    public mutating func update(height:Double,time:Double){
        guard height.isFinite,time.isFinite else{return}
        if let last=samples.last,time<=last.time{return}
        latest=height;if baseline==nil{baseline=height}
        samples.append((height,time));samples.removeAll{$0.time<time-5};if samples.count>500{samples.removeFirst(samples.count-500)}
        let delta=height-(baseline ?? height)
        guard samples.count>=3,time-(samples.first?.time ?? time)>=4,
              (samples.map(\.height).max() ?? height)-(samples.map(\.height).min() ?? height)<0.4,
              abs(delta)>=2.2,abs(delta)<=30 else{proposal=nil;return}
        let candidate=level+Int((delta/3).rounded())
        proposal=(-20...200).contains(candidate) ? candidate:nil
    }
    public mutating func confirm(_ floor:Int){level=max(-20,min(200,floor));baseline=latest;proposal=nil;samples=[]}
    public mutating func restart(){baseline=nil;latest=nil;proposal=nil;samples=[]}
}
