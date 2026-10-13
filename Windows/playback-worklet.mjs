import {PlaybackOnsetDetector} from './playback-onset.mjs';
class PlaybackInput extends AudioWorkletProcessor{
  constructor(){super();this.detector=new PlaybackOnsetDetector(-45);this.window=Math.max(Math.floor(sampleRate*.005),1);this.sum=0;this.count=0;this.start=0;this.lastLevel=-Infinity;this.port.onmessage=({data})=>{this.detector=new PlaybackOnsetDetector(data.thresholdDBFS);this.sum=0;this.count=0;this.lastLevel=-Infinity;};}
  process(inputs){
    const channel=inputs[0]?.[0],length=channel?.length??128;
    for(let i=0;i<length;i++){
      if(!this.count)this.start=(currentFrame+i)/sampleRate;
      const sample=channel?.[i]??0;if(!Number.isFinite(sample)){this.sum=0;this.count=0;continue;}this.sum+=sample*sample;this.count++;
      if(this.count===this.window){const level=20*Math.log10(Math.max(Math.sqrt(this.sum/this.count),.000001)),onset=this.detector.consume(level,this.start,this.count/sampleRate);if(this.start-this.lastLevel>=.1){this.lastLevel=this.start;this.port.postMessage({type:'level',level,ready:this.detector.isReady});}if(onset!=null)this.port.postMessage({type:'onset',clock:onset*1000});this.sum=0;this.count=0;}
    }
    return true;
  }
}
registerProcessor('playback-input',PlaybackInput);
