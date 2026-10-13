export class PlaybackCapture{
  constructor({onLevel=()=>{},onOnset=()=>{},onError=()=>{}}={}){this.onLevel=onLevel;this.onOnset=onOnset;this.onError=onError;this.stream=null;this.node=null;this.source=null;this.mute=null;this.closed=false;}
  async prepare(){
    if(!navigator.mediaDevices?.getDisplayMedia)throw new Error('Tab audio capture is unavailable. Use current Edge or Chrome.');
    const stream=await navigator.mediaDevices.getDisplayMedia({video:true,audio:{echoCancellation:false,noiseSuppression:false,autoGainControl:false,suppressLocalAudioPlayback:false},selfBrowserSurface:'exclude',systemAudio:'include',preferCurrentTab:false});
    if(this.closed){for(const track of stream.getTracks())track.stop();return;}
    this.stream=stream;
    if(!stream.getAudioTracks().length){this.stop();throw new Error('No playback audio was shared. Choose the Songsterr tab and enable Share tab audio in the browser picker.');}
    for(const track of stream.getTracks())track.onended=()=>this.onError('Playback capture stopped. Pause Songsterr and re-arm.');
    // No video element, recorder or network sink is created; audio is measured only.
  }
  async listen(context,thresholdDBFS){
    if(this.closed||!this.stream)return;
    await context.audioWorklet.addModule('playback-worklet.mjs');if(this.closed)return;
    this.node=new AudioWorkletNode(context,'playback-input',{channelCount:1,channelCountMode:'explicit',channelInterpretation:'speakers'});this.node.port.postMessage({thresholdDBFS});this.source=context.createMediaStreamSource(this.stream);this.mute=context.createGain();this.mute.gain.value=0;this.source.connect(this.node);this.node.connect(this.mute);this.mute.connect(context.destination);this.node.port.onmessage=({data})=>{if(this.closed)return;if(data.type==='level')this.onLevel(data.level,data.ready);if(data.type==='onset')this.onOnset(data.clock);};
  }
  stop(){this.closed=true;if(this.node){this.node.port.onmessage=null;this.node.disconnect();}this.source?.disconnect();this.mute?.disconnect();for(const track of this.stream?.getTracks()??[]){track.onended=null;track.stop();}this.stream=null;this.source=null;this.node=null;this.mute=null;}
}
