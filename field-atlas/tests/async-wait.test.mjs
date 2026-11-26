import test from 'node:test';
import assert from 'node:assert/strict';
import waitForAsync from './wait-for-async.cjs';
test('a Promise resolving false cannot acknowledge a pending browser write',async()=>{
 let calls=0;
 const page={evaluate:async()=>++calls>=3 ? 'durable-record':false};
 assert.equal(await waitForAsync(page,()=>{},undefined,{polling:1,timeout:1000}),'durable-record');
 assert.equal(calls,3);
});
test('a write that never completes fails verification',async()=>{
 await assert.rejects(waitForAsync({evaluate:async()=>false},()=>{},undefined,{polling:1,timeout:10}),/Timed out/);
});
