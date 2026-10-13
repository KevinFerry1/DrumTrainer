import {TransientDetector} from './core.mjs';
import {extractFeatures} from './audio-core.mjs';
class KickInput extends AudioWorkletProcessor {
  constructor() {
    super(); this.detector = new TransientDetector(sampleRate); this.blocks = 0; this.peak = 0;
    this.history = new Float64Array(Math.ceil(sampleRate*.08)); this.pending = [];
    this.port.onmessage = ({data}) => { this.detector.threshold = data.threshold; this.detector.lockout = data.lockout; };
  }
  process(inputs) {
    const channels = inputs[0];
    if (!channels?.length) return true;
    for (let i=0;i<channels[0].length;i++) {
      let sample = 0,mono = 0;
      for (const c of channels) { if (Math.abs(c[i]) > Math.abs(sample)) sample = c[i]; mono += c[i]; }
      mono /= channels.length;
      this.peak = Math.max(this.peak,Math.abs(sample));
      const frame = currentFrame+i,time = frame/sampleRate*1000;
      this.history[frame%this.history.length] = mono;
      if (this.detector.sample(sample,time)) this.pending.push({frame,time,amplitude:Math.abs(sample)});
      const post = Math.max(Math.round(sampleRate*.014),16),pre = Math.max(Math.round(sampleRate*.002),1);
      while (this.pending.length && frame > this.pending[0].frame+post) {
        const hit = this.pending.shift(),first = Math.max(0,hit.frame-pre),last = hit.frame+post;
        const samples = new Float64Array(last-first+1);
        for(let n=first;n<=last;n++)samples[n-first]=this.history[n%this.history.length];
        this.port.postMessage({type:'hit',time:hit.time,amplitude:hit.amplitude,features:extractFeatures(samples,sampleRate)});
      }
    }
    if (++this.blocks >= 16) { this.port.postMessage({type:'level',peak:this.peak}); this.blocks = 0; this.peak = 0; }
    return true;
  }
}
registerProcessor('kick-input',KickInput);
