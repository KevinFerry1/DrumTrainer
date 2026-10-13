import {TransientDetector} from './core.mjs';
class KickInput extends AudioWorkletProcessor {
  constructor() {
    super(); this.detector = new TransientDetector(sampleRate); this.blocks = 0; this.peak = 0;
    this.port.onmessage = ({data}) => { this.detector.threshold = data.threshold; this.detector.lockout = data.lockout; };
  }
  process(inputs) {
    const channels = inputs[0];
    if (!channels?.length) return true;
    for (let i=0;i<channels[0].length;i++) {
      let sample = 0;
      for (const c of channels) if (Math.abs(c[i]) > Math.abs(sample)) sample = c[i];
      this.peak = Math.max(this.peak,Math.abs(sample));
      const time = (currentFrame+i)/sampleRate*1000;
      if (this.detector.sample(sample,time)) this.port.postMessage({type:'hit',time,amplitude:Math.abs(sample)});
    }
    if (++this.blocks >= 16) { this.port.postMessage({type:'level',peak:this.peak}); this.blocks = 0; this.peak = 0; }
    return true;
  }
}
registerProcessor('kick-input',KickInput);
