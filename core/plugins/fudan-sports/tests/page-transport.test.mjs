// SPDX-License-Identifier: GPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
const source=readFileSync(new URL('../../../platform/android/adapter/src/main/assets/dansheng-page-transport.js',import.meta.url),'utf8');
function run(p, globals) {
  const window={};const context=vm.createContext({window,AbortController,setTimeout,clearTimeout,...globals});
  const start=vm.runInContext(source,context);
  start('fixtureBox','request',{method:'GET',url:'https://fixture.invalid/api',transport:'fetch',headers:{},timeout_ms:1000,max_body_chars:10000,...p});
  return window;
}
test('page-context fetch uses current WAF wrapper with same-origin credentials', async()=>{
  let captured;
  const window=run({},{});
  // Initial absent fetch fails rather than silently substituting HTTP.
  assert.equal(window.fixtureBox.request.value.error,'BrowserRequestFailed');
  const w={fetch:async(url,init)=>{captured={url,init};return {status:200,url:url+'?dynamic=fixture',text:async()=>'{"e":0}'}}};
  const context=vm.createContext({window:w,AbortController,setTimeout,clearTimeout});
  vm.runInContext(source,context)('box','r',{method:'GET',url:'/api',transport:'fetch',headers:{},timeout_ms:1000,max_body_chars:1000});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(captured.init.credentials,'same-origin');assert.equal(w.box.r.value.url,'/api?dynamic=fixture');
});
test('POST uses current XMLHttpRequest, FormData and sign-key; timeout uncertain',()=>{
  let captured;
  class Form { constructor(){this.fields={}} append(k,v){this.fields[k]=v} }
  class Xhr { open(method,url){this.method=method;this.url=url+'?dynamic=yes'}
    setRequestHeader(k,v){this[k]=v} send(form){captured={xhr:this,form};this.status=200;this.responseURL=this.url;this.responseText='{"e":0}';this.onload()} abort(){} }
  const w=run({method:'POST',transport:'xhr',mutating:true,headers:{'sign-key':'fixturepost'},form_fields:{data:'synthetic'}},{XMLHttpRequest:Xhr,FormData:Form});
  assert.equal(captured.xhr['sign-key'],'fixturepost');assert.equal(captured.form.fields.data,'synthetic');
  assert.match(w.fixtureBox.request.value.url,/dynamic=yes/);
  class Timed extends Xhr { send(){this.ontimeout()} }
  assert.equal(run({method:'POST',transport:'xhr',mutating:true},{XMLHttpRequest:Timed}).fixtureBox.request.value.error,'NeedsReconciliation');
});
test('XHR status zero after a write is uncertainty, never an ordinary response',()=>{
  class Zero { open(){} setRequestHeader(){} send(){this.status=0;this.responseText='';this.onload()} abort(){} }
  const w=run({method:'POST',transport:'xhr',mutating:true},{XMLHttpRequest:Zero});
  assert.equal(w.fixtureBox.request.value.error,'NeedsReconciliation');
});
test('response body interrupted after POST preserves uncertainty',async()=>{
  const window={fetch:async()=>({status:200,url:'/api',text:async()=>{throw new Error('synthetic body interruption')}})};
  vm.runInContext(source,vm.createContext({window,AbortController,setTimeout,clearTimeout}))('box','r',{
    method:'POST',url:'/api',mutating:true,transport:'fetch',headers:{},timeout_ms:1000,max_body_chars:1000});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(window.box.r.value.error,'NeedsReconciliation');
});
test('page transport retains safe pagination and discards credential headers',async()=>{
  const safeLink='<https://fixture.invalid/api?page=2>; rel="next"';
  const window={fetch:async(url)=>({status:200,url,text:async()=>'[]',headers:{get:name=>({
    'content-type':'application/json','link':safeLink,'set-cookie':'SYNTHETIC_SECRET',
    'authorization':'SYNTHETIC_SECRET'
  })[name]??null}})};
  vm.runInContext(source,vm.createContext({window,URL,AbortController,setTimeout,clearTimeout}))('box','r',{
    method:'GET',url:'https://fixture.invalid/api',transport:'fetch',headers:{},timeout_ms:1000,max_body_chars:1000});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(window.box.r.value.headers.link,safeLink);
  assert.equal(window.box.r.value.headers['content-type'],'application/json');
  assert.equal(JSON.stringify(window.box.r.value).includes('SYNTHETIC_SECRET'),false);
});
test('signed and cross-origin Link headers fail without returning a partial list',async()=>{
  for(const link of [
    '<https://unrelated.invalid/api?page=2>; rel="next"',
    '<https://fixture.invalid/api?access_token=SYNTHETIC_SECRET>; rel="next"',
    '<https://fixture.invalid/api?api_key=SYNTHETIC_SECRET>; rel="next"',
    '<https://fixture.invalid/api?sig=SYNTHETIC_SECRET>; rel="next"'
  ]){
    const window={fetch:async(url)=>({status:200,url,text:async()=>'[]',headers:{get:name=>name==='link'?link:null}})};
    vm.runInContext(source,vm.createContext({window,URL,AbortController,setTimeout,clearTimeout}))('box','r',{
      method:'GET',url:'https://fixture.invalid/api',transport:'fetch',headers:{},timeout_ms:1000,max_body_chars:1000});
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(window.box.r.value.error,'BrowserRequestFailed');
    assert.equal(JSON.stringify(window.box.r.value).includes('SYNTHETIC_SECRET'),false);
  }
});
