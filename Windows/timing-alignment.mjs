import {median} from './native-scoring.mjs';
// TimingAlignmentCollector.swift. MIDI compensation applies to the entire kit.
export class TimingAlignmentCollector{
  constructor(source,voice=null){this.source=source;this.voice=voice;this.referenceTimes=[];this.events=[];}
  recordReference(timeNanoseconds){this.referenceTimes.push(timeNanoseconds);}
  record(event){if(event.source!==this.source||this.voice!=null&&event.voice!==this.voice||['unknown','metronome'].includes(event.voice))return;this.events.push(event);}
  measurement(maximumOffsetMilliseconds=400){
    const maximumOffset=Math.round(maximumOffsetMilliseconds*1e6),remaining=[...this.events].sort((a,b)=>a.sessionTimeNanoseconds-b.sessionTimeNanoseconds),offsets=[];
    for(const reference of [...this.referenceTimes].sort((a,b)=>a-b)){let best=-1,distance=Infinity;remaining.forEach((event,index)=>{const d=Math.abs(reference-event.sessionTimeNanoseconds);if(d<=maximumOffset&&d<distance){best=index;distance=d;}});if(best>=0){const [event]=remaining.splice(best,1);offsets.push((event.sessionTimeNanoseconds-reference)/1e6);}}
    if(!offsets.length)return null;const compensation=median(offsets);return{compensationMilliseconds:compensation,medianAbsoluteDeviationMilliseconds:median(offsets.map(v=>Math.abs(v-compensation))),sampleCount:offsets.length,referenceCount:this.referenceTimes.length,missedCount:Math.max(this.referenceTimes.length-offsets.length,0)};
  }
}
