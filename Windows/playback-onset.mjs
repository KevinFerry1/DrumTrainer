// PlaybackOnsetDetector.swift: 300 ms observed quiet, then 20 ms sustained sound.
export class PlaybackOnsetDetector{
  constructor(thresholdDBFS){this.thresholdDBFS=Number.isFinite(thresholdDBFS)?Math.min(Math.max(thresholdDBFS,-80),-10):-45;this.isReady=false;this.hasTriggered=false;this.quietDuration=0;this.loudDuration=0;this.candidateTime=null;this.previousEnd=null;}
  observeSilentCaptureInterval(){if(this.hasTriggered)return;this.isReady=true;this.quietDuration=.3;this.loudDuration=0;this.candidateTime=null;this.previousEnd=null;}
  consume(levelDBFS,time,duration){
    if(this.hasTriggered||![levelDBFS,time,duration].every(Number.isFinite)||duration<=0||duration>.1)return null;
    if(this.previousEnd!=null&&time<this.previousEnd-.001)return null;
    if(this.previousEnd!=null&&time-this.previousEnd>.25){this.quietDuration=0;this.loudDuration=0;this.candidateTime=null;this.isReady=false;}
    this.previousEnd=time+duration;
    if(levelDBFS<this.thresholdDBFS){this.quietDuration+=duration;this.loudDuration=0;this.candidateTime=null;if(this.quietDuration>=.3)this.isReady=true;return null;}
    this.quietDuration=0;if(!this.isReady)return null;if(this.candidateTime==null)this.candidateTime=time;this.loudDuration+=duration;if(this.loudDuration<.02)return null;this.hasTriggered=true;return this.candidateTime;
  }
}
export function playbackStart({onset,now,armedAt,offset=0,duration,tolerance=100,latestDropped=null}){
  if(![onset,now,armedAt,duration,tolerance].every(Number.isFinite)||onset<armedAt||now-onset< -250||now-onset>2000)throw new Error('Playback arrived with an unreliable timestamp. Cancel and re-arm before grading.');
  offset=Number.isFinite(offset)?Math.min(Math.max(offset,-5000),5000):0;const start=onset+offset;
  if(latestDropped!=null&&latestDropped>=start-tolerance)throw new Error('Too many drum hits arrived before playback was confirmed. Re-arm and wait for Songsterr before playing.');
  if(start+duration<=now)throw new Error('The start offset places this section in the past. Adjust the offset and re-arm.');return start;
}
