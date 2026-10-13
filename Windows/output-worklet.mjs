import {OutputLimiter} from './sound-synthesis.mjs';
class OutputProcessor extends AudioWorkletProcessor{
  constructor(){super();this.limiter=new OutputLimiter(sampleRate);this.peak=0;this.squares=0;this.samples=0;this.reduction=0;this.frames=0;this.port.onmessage=({data})=>{this.limiter.enabled=data.enabled;this.limiter.ceilingDBFS=data.ceilingDBFS;};}
  process(inputs,outputs){
    const input=inputs[0],output=outputs[0];if(!output?.length)return true;
    for(let frame=0;frame<output[0].length;frame++){
      let peak=0;for(let channel=0;channel<output.length;channel++)peak=Math.max(peak,Math.abs(input?.[channel]?.[frame]??input?.[0]?.[frame]??0));
      const gain=this.limiter.gainForPeak(peak);
      for(let channel=0;channel<output.length;channel++){const v=(input?.[channel]?.[frame]??input?.[0]?.[frame]??0)*gain;output[channel][frame]=v;this.peak=Math.max(this.peak,Math.abs(v));this.squares+=v*v;this.samples++;}
      this.reduction=Math.max(this.reduction,-20*Math.log10(Math.max(this.limiter.gain,1e-12)));this.frames++;
    }
    if(this.frames>=sampleRate*.1){const db=v=>v>0?Math.max(20*Math.log10(v),-80):-80;this.port.postMessage({peakDBFS:db(this.peak),rmsDBFS:db(Math.sqrt(this.squares/Math.max(this.samples,1))),limiterReductionDB:this.reduction});this.peak=0;this.squares=0;this.samples=0;this.reduction=0;this.frames=0;}
    return true;
  }
}
registerProcessor('drum-output',OutputProcessor);
