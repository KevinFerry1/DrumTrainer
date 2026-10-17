import {nativeScore} from './native-scoring.mjs';
import {validateSettings,validateProgress} from './backup-state.mjs';
// Platform-independent practice logic. Times are milliseconds relative to the exercise start.
export const voices = {
  kick: 'Kick', snare: 'Snare', crossStick: 'Cross-stick', highTom: 'High tom', midTom: 'Mid tom', lowTom: 'Low tom',
  closedHiHat: 'Closed hi-hat', openHiHat: 'Open hi-hat', pedalHiHat: 'Pedal hi-hat', ride: 'Ride', rideBell: 'Ride bell',
  crash1: 'Crash 1', crash2: 'Crash 2', china: 'China', splash: 'Splash', other: 'Other', unknown: 'Unknown',
};
export const gm = {35:'kick',36:'kick',37:'crossStick',38:'snare',40:'snare',41:'lowTom',43:'lowTom',45:'midTom',47:'midTom',48:'highTom',50:'highTom',42:'closedHiHat',44:'pedalHiHat',46:'openHiHat',49:'crash1',52:'china',55:'splash',57:'crash2',51:'ride',53:'rideBell',59:'ride'};
export const subdivisions = {eighths: 2, sixteenths: 4, triplets: 3};
const cymbals = ['crash2','ride','rideBell','closedHiHat','openHiHat','china'];
const hits = (slots, voice = 'kick', allowedVoices = []) => slots.map(slot => ({slot, voice, allowedVoices}));
const range = n => Array.from({length: n}, (_, i) => i);
const repeatSlots = slots => range(4).flatMap(beat => slots.map(slot => beat * 4 + slot));
const exercise = (id, name, subdivision, notes, guide) => ({id, name, subdivision, hits: notes, guide});
export const exercises = [
  exercise('straightEighths','Straight 8ths','eighths',hits(range(8)), 'Even, relaxed strokes on 1 & 2 & 3 & 4 &.'),
  exercise('straightSixteenths','Straight 16ths','sixteenths',hits(range(16)), 'Continuous 1 e & a with identical spacing.'),
  exercise('triplets','8th-note triplets','triplets',hits(range(12)), 'Three evenly spaced hits per beat: 1-trip-let.'),
  exercise('offbeatEighths','Offbeat 8ths','eighths',hits([1,3,5,7]), 'Play each &; leave the numbered beats empty.'),
  exercise('gallop','Gallop','sixteenths',hits(repeatSlots([0,2,3])), 'One hit on the beat, then two quick sixteenths on &-a.'),
  exercise('reverseGallop','Reverse gallop','sixteenths',hits(repeatSlots([0,1,2])), 'Three hits on 1-e-& followed by the a rest.'),
  exercise('threeNoteBursts','Three-note bursts','sixteenths',hits(repeatSlots([0,1,2])), 'Three sixteenths, one rest, repeated every beat.'),
  exercise('fourOnFourOff','Four on / four off','sixteenths',hits([0,1,2,3,8,9,10,11]), 'One beat of 16ths followed by one full beat of rest.'),
  exercise('displacedSixteenths','Displaced 16ths','sixteenths',hits([0,1,2,4,5,7,8,10,11,13,14,15]), 'A changing three-note shape shifts the missing sixteenth.'),
  exercise('basicRockGroove','Rock backbeat','eighths',[...hits(range(8),'closedHiHat',['ride']),...hits([2,6],'snare',['crossStick']),...hits([0,4,5])], '8th-note hat, snare on 2 and 4, kick on 1, 3, and the & of 3.'),
  exercise('doubleBassBackbeat','Double-bass backbeat','sixteenths',[...hits(range(16)),...hits([0,2,4,6,8,10,12,14],'crash1',cymbals),...hits([4,12],'snare',['crossStick'])], 'Continuous 16th-note feet under 8th-note cymbal and snare on 2 and 4.'),
  exercise('discoGroove','Open-hat groove','eighths',[...hits(range(8),'openHiHat'),...hits([0,2,4,6]),...hits([2,6],'snare',['crossStick'])], 'Quarter-note kick, snare on 2 and 4, open hi-hat on every 8th note.'),
  exercise('alternatingBlast','Alternating blast','sixteenths',[...hits([0,2,4,6,8,10,12,14],'crash1',cymbals),...hits([0,2,4,6,8,10,12,14]),...hits([1,3,5,7,9,11,13,15],'snare',['crossStick'])], 'Alternate cymbal-plus-kick with snare on neighboring 16ths.'),
  exercise('simultaneousBlast','Unison blast','eighths',[...hits(range(8),'crash1',cymbals),...hits(range(8),'snare',['crossStick']),...hits(range(8))], 'Cymbal, snare, and kick together on every 8th note.'),
  exercise('tripletBlast','Triplet blast','triplets',range(4).flatMap(b => [...hits([b*3],'crash1',cymbals),...hits([b*3,b*3+2]),...hits([b*3+1],'snare',['crossStick'])]), 'Cymbal-plus-kick, snare, then kick across each triplet beat.'),
];

const boundedNumber = (v, min, max) => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;
function requireValid(ok, message) { if (!ok) throw new Error(message); }
export function validateDefinition(d) {
  requireValid(d && typeof d.name === 'string' && d.name.length <= 1024, 'Invalid exercise name.');
  if (d.sequenceSteps != null) {
    requireValid(Array.isArray(d.sequenceSteps) && d.sequenceSteps.length > 0 && d.sequenceSteps.length <= 32, 'Invalid sequence steps.');
    requireValid(Number.isInteger(d.sequenceRepeats ?? 1) && boundedNumber(d.sequenceRepeats ?? 1,1,16), 'Invalid sequence repeats.');
    let measures = 0;
    for (const s of d.sequenceSteps) {
      validateDefinition({...s, sequenceSteps: undefined});
      requireValid(Number.isInteger(s.repeats) && boundedNumber(s.repeats,1,16), 'Invalid step repeats.');
      measures += s.repeats;
    }
    requireValid(measures * (d.sequenceRepeats ?? 1) <= 128, 'Sequence exceeds 128 measures.');
  } else {
    requireValid(Object.hasOwn(subdivisions, d.subdivision) && Array.isArray(d.hits) && d.hits.length > 0 && d.hits.length <= 288, 'Invalid or empty custom measure.');
    const keys = new Set();
    for (const h of d.hits) {
      const key = `${h.slot}/${h.voice}`;
      requireValid(Number.isInteger(h.slot) && h.slot >= 0 && h.slot < subdivisions[d.subdivision]*4 && Object.hasOwn(voices,h.voice) && !keys.has(key), 'Invalid or duplicate drum note.');
      requireValid(h.allowedVoices == null || (Array.isArray(h.allowedVoices) && h.allowedVoices.every(v => Object.hasOwn(voices,v))), 'Invalid alternate voice.');
      requireValid([h.accent,h.ghost].every(v => v == null || typeof v === 'boolean'), 'Invalid dynamics.');
      keys.add(key);
    }
  }
  return d;
}

export function makePattern(definition, bpm, repeats, options = {}) {
  validateDefinition(definition);
  requireValid(boundedNumber(bpm,40,240) && Number.isInteger(repeats) && boundedNumber(repeats,1,16), 'Use 40–240 BPM and 1–16 repeats.');
  const sequence = definition.sequenceSteps
    ? range(definition.sequenceRepeats ?? 1).flatMap(() => definition.sequenceSteps.flatMap(s => range(s.repeats).map(() => s)))
    : range(repeats).map(() => definition);
  const beatMs = 60000/bpm;
  const uid = () => globalThis.crypto?.randomUUID?.() ?? `id-${Math.random().toString(36).slice(2)}`;
  const notes = sequence.flatMap((measure,i) => {
    const groups = new Map();
    for (const h of measure.hits) if (measure.hits.filter(n => n.slot === h.slot).length > 1 && !groups.has(h.slot)) groups.set(h.slot,uid());
    return measure.hits.map(h => {
      const ns = Math.round((i*4+h.slot/subdivisions[measure.subdivision])*60000000000/bpm);
      return {...h,id:uid(),time:ns/1e6,timeNanoseconds:ns,measure:i+1,beat:Math.floor(h.slot/subdivisions[measure.subdivision])+1,subdivision:h.slot%subdivisions[measure.subdivision],simultaneousGroupID:groups.get(h.slot) ?? null,matchingToleranceNanoseconds:Math.round((options.tolerance ?? 100)*1e6),minimumAccentVelocity:h.accent ? options.accentFloor===null ? null:(options.accentFloor ?? 100)/127:null,minimumAccentContrast:h.accent ? (options.accentContrast ?? 18)/127:null,maximumGhostVelocity:h.ghost ? options.ghostCeiling===null ? null:(options.ghostCeiling ?? 50)/127:null,minimumGhostContrast:h.ghost ? (options.ghostContrast ?? 18)/127:null};
    });
  });
  notes.sort((a,b) => a.time-b.time || (a.voice < b.voice ? -1:a.voice > b.voice ? 1:0));
  requireValid(notes.length <= 10000, 'Shorten this exercise to at most 10,000 notes.');
  const durationNanoseconds=Math.round(sequence.length*4*60000000000/bpm);
  return {id:uid(),name:definition.name,bpm,beatMs,beatsPerMeasure:4,subdivision:definition.subdivision ?? sequence[0].subdivision,measures:sequence.length,duration:durationNanoseconds/1e6,durationNanoseconds,notes,measureSubdivisions:sequence.map(s => s.subdivision),measureLabels:definition.sequenceSteps?sequence.map(s => s.name):null,measureStarts:Array.from({length:sequence.length+1},(_,i) => Math.round(i*4*60000000000/bpm)/1e6),referenceBeats:Array.from({length:sequence.length*4},(_,i) => ({time:Math.round(i*60000000000/bpm)/1e6,measure:Math.floor(i/4)+1,beat:i%4+1,isAccent:i%4===0}))};
}

export const median = values => {
  if (!values.length) return null;
  const v = [...values].sort((a,b) => a-b), mid = Math.floor(v.length/2);
  return v.length%2 ? v[mid] : (v[mid-1]+v[mid])/2;
};

// Use the Mac-compatible matching, metrics, dynamics and clean-run pipeline.
export const score = nativeScore;

export class TransientDetector {
  constructor(sampleRate, threshold = .12, lockout = 40) {
    this.sampleRate = sampleRate; this.threshold = threshold; this.lockout = lockout;
    this.armed = true; this.quiet = 0; this.lastHit = -Infinity; this.above = false;
  }
  sample(value, time) {
    const amplitude = Math.min(1,Math.abs(value)), above = amplitude >= this.threshold;
    if (!this.armed) {
      this.quiet = amplitude <= this.threshold*.35 ? this.quiet+1 : 0;
      if (time-this.lastHit >= this.lockout && this.quiet >= this.sampleRate*.012) this.armed = true;
    }
    const hit = this.armed && !this.above && above && time-this.lastHit >= this.lockout;
    if (hit) { this.armed = false; this.quiet = 0; this.lastHit = time; }
    this.above = above;
    return hit;
  }
}

export function importBackup(value) {
  requireValid(value && typeof value === 'object', 'Invalid backup.');
  if (value.format === 'DrumTrainerWindows') {
    requireValid(value.version === 1 && Array.isArray(value.exercises) && Array.isArray(value.sessions), 'Unsupported Windows backup.');
    requireValid(value.exercises.length <= 1000 && value.sessions.length <= 2000, 'Backup is too large.');
    value.exercises.forEach(e => { requireValid(typeof e.id === 'string','Invalid exercise ID.'); validateDefinition(e.definition); });
    value.sessions.forEach(s => {
      requireValid(typeof s.id === 'string' && typeof s.name === 'string' && boundedNumber(s.bpm,40,240) && s.metrics && boundedNumber(s.metrics.recall,0,1) && boundedNumber(s.metrics.precision,0,1), 'Invalid session.');
      requireValid(Array.isArray(s.evidence) && s.evidence.length <= 10000 && s.evidence.every(e => boundedNumber(e.time,-2000,3600000) && Object.hasOwn(voices,e.voice)), 'Invalid session evidence.');
      requireValid(typeof s.date === 'string' && Number.isFinite(Date.parse(s.date)) && s.pattern && boundedNumber(s.pattern.beatMs,250,1500) && boundedNumber(s.pattern.measures,1,128) && boundedNumber(s.pattern.duration,1,3600000), 'Invalid session pattern or date.');
      requireValid(Array.isArray(s.pattern.notes) && s.pattern.notes.length <= 10000 && s.pattern.notes.every(n => boundedNumber(n.time,0,3600000) && Object.hasOwn(voices,n.voice)), 'Invalid pattern notes.');
      requireValid(Array.isArray(s.metrics.results) && s.metrics.results.length <= 20000 && s.metrics.results.every(r => r && ['correct','wrongVoice','missed','extra','ambiguous'].includes(r.status) && (r.offset == null || boundedNumber(r.offset,-1000,1000))), 'Invalid match results.');
      requireValid(Array.isArray(s.metrics.perVoice) && s.metrics.perVoice.length <= 18 && s.metrics.perVoice.every(v => v && Object.hasOwn(voices,v.voice) && (v.error == null || boundedNumber(v.error,0,1000))), 'Invalid voice metrics.');
      requireValid(['error','bias','consistency','spread'].every(k => s.metrics[k] == null || boundedNumber(s.metrics[k],-3600000,3600000)), 'Invalid timing metrics.');
      requireValid(['expected','played','correct','missed','extra','wrong'].every(k => Number.isInteger(s.metrics[k]) && boundedNumber(s.metrics[k],0,10000)), 'Invalid session counts.');
      requireValid(s.notes==null||typeof s.notes==='string','Invalid session notes.');requireValid(s.tags==null||(Array.isArray(s.tags)&&s.tags.every(t=>typeof t==='string'&&t.length<=1024)),'Invalid session tags.');
    });
    requireValid(value.nativeArchives == null || (Array.isArray(value.nativeArchives) && value.nativeArchives.length <= 20), 'Invalid original Mac archives.');
    for (const archive of value.nativeArchives ?? []) {
      requireValid(archive?.format !== 'DrumTrainerWindows', 'Original Mac archives must use the Mac format.');
      importBackup(archive);
    }
    requireValid(value.songs==null||(Array.isArray(value.songs)&&value.songs.length<=500),'Invalid song library.');
    for(const key of ['deletedSessionIDs','deletedSongIDs'])requireValid(value[key]==null||(Array.isArray(value[key])&&value[key].length<=10000&&value[key].every(id=>typeof id==='string')),'Invalid deleted-record identifiers.');
    validateSettings(value.settings,voices);validateProgress(value.progress);
    return {exercises:value.exercises,sessions:value.sessions,nativeArchives:value.nativeArchives ?? [],songs:value.songs??[],progress:value.progress??null,settings:value.settings??null,deletedSessionIDs:value.deletedSessionIDs??[],deletedSongIDs:value.deletedSongIDs??[]};
  }
  requireValid(Number.isInteger(value.schemaVersion) && value.schemaVersion >= 1 && value.schemaVersion <= 11 && Array.isArray(value.customExercises) && Array.isArray(value.sessions), 'Choose a DrumTrainer Mac or Windows JSON backup.');
  requireValid(value.customExercises.length <= 1000 && value.sessions.length <= 10000, 'Mac backup is too large.');
  requireValid(value.sessions.every(s => s && typeof s.id === 'string' && typeof s.exerciseName === 'string' && boundedNumber(s.bpm,40,240) && boundedNumber(s.recall,0,1) && (s.medianAbsoluteErrorMilliseconds == null || boundedNumber(s.medianAbsoluteErrorMilliseconds,0,3600000)) && (typeof s.completedAt === 'number' ? Number.isFinite(s.completedAt) : typeof s.completedAt === 'string' && Number.isFinite(Date.parse(s.completedAt)))), 'Invalid Mac history summary.');
  const saved = value.customExercises.filter(e => !e.instrument || e.instrument === 'drums');
  saved.forEach(e => { requireValid(typeof e.id === 'string','Invalid Mac exercise ID.'); validateDefinition(e.definition); });
  // Retain the complete native archive, including songs and session evidence, without rewriting it.
  return {exercises:saved,sessions:[],nativeArchives:[value]};
}
