const test = require('node:test');
const assert = require('node:assert/strict');
const {TimeStretch} = require('../time_stretch');
const rateHz=24000;
function tone(seconds) { return Float32Array.from({length:Math.round(seconds*rateHz)}, (_, i)=>0.3*Math.sin(2*Math.PI*220*i/rateHz)); }
function join(blocks) { const out=new Float32Array(blocks.reduce((n,b)=>n+b.length,0));let p=0;for(const b of blocks){out.set(b,p);p+=b.length;}return out; }
for (const speed of [0.5,0.8,1,1.25,1.5,2]) {
  test(`speed ${speed} preserves pitch and has the requested duration`,()=>{
    const input=tone(3), stretch=new TimeStretch(speed);
    const out=join([stretch.push(input),stretch.push(new Float32Array(0),true)]);
    assert.equal(out.length,Math.round(input.length/speed));
    let crossings=0;const start=2400,end=out.length-2400;
    for(let i=start+1;i<end;i++)if(out[i-1]<=0&&out[i]>0)crossings++;
    const frequency=crossings*rateHz/(end-start);
    assert.ok(Math.abs(frequency-220)<2,`Measured pitch ${frequency}`);
    for(const x of out)assert.ok(Number.isFinite(x)&&Math.abs(x)<=0.301);
  });
}
test('input packet boundaries do not change stretched waveform',()=>{
  const input=tone(3), whole=new TimeStretch(1.5), packets=new TimeStretch(1.5);
  const reference=join([whole.push(input),whole.push(new Float32Array(0),true)]);
  const pieces=[];
  for(let i=0;i<input.length;i+=1783)pieces.push(packets.push(input.slice(i,i+1783)));
  pieces.push(packets.push(new Float32Array(0),true));
  assert.deepEqual(join(pieces),reference);
});
test('short and silent inputs finish with exact duration and finite samples',()=>{
  for(const size of [1,200,480,500,2000])for(const speed of [0.5,1,2]) {
    const s=new TimeStretch(speed), input=new Float32Array(size);
    const out=join([s.push(input),s.push(new Float32Array(0),true)]);
    assert.equal(out.length,Math.round(size/speed));assert.ok(out.every(x=>x===0));
  }
});
