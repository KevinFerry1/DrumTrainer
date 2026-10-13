import test from 'node:test';
import assert from 'node:assert/strict';
import {crc32,blobCRC,portableZIP} from './portable-zip.mjs';
test('ZIP CRC matches standard vector and incremental chunks',async()=>{
  const bytes=new TextEncoder().encode('123456789');assert.equal((crc32(bytes)^0xffffffff)>>>0,0xcbf43926);assert.equal(await blobCRC(new Blob([bytes])),0xcbf43926);assert.equal((crc32(bytes.slice(4),crc32(bytes.slice(0,4)))^0xffffffff)>>>0,0xcbf43926);
});
test('portable backup headers, offsets, UTF8 names and exact audio payloads are consistent',async()=>{
  const entries=[{name:'Practice-backup.json',blob:new Blob(['{"sessions":[]}'])},{name:'Recordings/é-session.wav',blob:new Blob([new Uint8Array([82,73,70,70,0,255,128,42])])}],zip=await portableZIP(entries),bytes=new Uint8Array(await zip.arrayBuffer()),view=new DataView(bytes.buffer);
  const end=bytes.length-22;assert.equal(view.getUint32(end,true),0x06054b50);assert.equal(view.getUint16(end+10,true),2);let central=view.getUint32(end+16,true),local=0;
  for(const entry of entries){assert.equal(view.getUint32(local,true),0x04034b50);assert.equal(view.getUint16(local+6,true),0x0800);assert.equal(view.getUint16(local+8,true),0);const n=view.getUint16(local+26,true),size=view.getUint32(local+18,true);assert.equal(new TextDecoder().decode(bytes.slice(local+30,local+30+n)),entry.name);assert.deepEqual(bytes.slice(local+30+n,local+30+n+size),new Uint8Array(await entry.blob.arrayBuffer()));assert.equal(view.getUint32(local+14,true),await blobCRC(entry.blob));assert.equal(view.getUint32(central,true),0x02014b50);assert.equal(view.getUint32(central+42,true),local);assert.equal(view.getUint32(central+16,true),view.getUint32(local+14,true));central+=46+n;local+=30+n+size;}
  assert.equal(central,end);assert.equal(local,view.getUint32(end+16,true));
});
test('portable ZIP rejects traversal, collisions and excessive total bytes before downloading',async()=>{
  for(const name of ['../private','/absolute','path/../bad','path\\bad','path//bad'])await assert.rejects(portableZIP([{name,blob:new Blob(['x'])}]));
  await assert.rejects(portableZIP([{name:'a',blob:new Blob()},{name:'a',blob:new Blob()}]));await assert.rejects(portableZIP([{name:'a',blob:new Blob(['0123456789'])}],{maxBytes:20}));
});
