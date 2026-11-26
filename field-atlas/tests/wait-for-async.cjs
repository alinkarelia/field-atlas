// page.waitForFunction treats a returned Promise as truthy before it resolves.
// Database checks must await the actual value on every poll.
module.exports=async function waitForAsync(page,predicate,arg,{timeout=8000,polling=100}={}){
 const deadline=Date.now()+timeout;
 while(true){
  const value=await page.evaluate(predicate,arg);
  if(value)return value;
  if(Date.now()>=deadline)throw Error('Timed out waiting for asynchronous browser state');
  await new Promise(resolve=>setTimeout(resolve,Math.min(polling,Math.max(1,deadline-Date.now()))));
 }
};
