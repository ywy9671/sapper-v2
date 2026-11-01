// Run inside a disposable Sapper container. No model calls or external network.
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import readline from 'node:readline';
import assert from 'node:assert/strict';
const task='zfixture', dir='/work/runs/'+task;
mkdirSync(dir,{recursive:true});
execFileSync('sapper',['--store',dir+'/.sapper','init','--goal','fixture']);
mkdirSync('/tmp/zcode-fixture',{recursive:true});
writeFileSync('/tmp/zcode-fixture/docker','#!/bin/sh\nshift\nshift\nexec "$@"\n');
chmodSync('/tmp/zcode-fixture/docker',0o755);
const server=createServer((req,res)=>{res.setHeader('Content-Type','application/json');if(req.url==='/tasks')res.end(JSON.stringify({tasks:[{id:task}]}));else if(req.url?.startsWith('/findings?'))res.end(JSON.stringify({report:'',sections:[]}));else{res.statusCode=404;res.end('{}')}});
await new Promise(r=>server.listen(18790,'127.0.0.1',r));
const child=spawn('node',['/tmp/zcode-server.mjs'],{env:{...process.env,PATH:'/tmp/zcode-fixture:'+process.env.PATH},stdio:['pipe','pipe','inherit']});
const responses=new Map();const rl=readline.createInterface({input:child.stdout});rl.on('line',line=>{const r=JSON.parse(line);responses.get(r.id)?.(r);responses.delete(r.id)});let next=0;
async function request(method,params={}){const id=++next;const promise=new Promise((resolve,reject)=>{responses.set(id,resolve);setTimeout(()=>reject(Error('MCP timeout')),10000).unref()});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');const result=await promise;if(result.error||result.result?.isError)throw Error(JSON.stringify(result));return result.result}
async function tool(name,args){return request('tools/call',{name,arguments:args})}
try{
 await request('initialize',{protocolVersion:'2024-11-05'});
 const list=await request('tools/list');assert.equal(list.tools.length,7);assert(!list.tools.some(t=>t.name==='open_terminal'));
 await tool('list_tasks',{});
 await tool('inspect_task',{id:task});
 const fact=await tool('record_fact',{id:task,title:'Fixture',description:'Observed fixture',kind:'note',evidence:'local test'});
 assert.match(fact.content[0].text,/Observed fixture/);
 const factId=JSON.parse(fact.content[0].text).split('\n')[0];
 const intent=await tool('record_intent',{id:task,title:'Follow up',description:'Review fixture',from:factId});
 assert.match(intent.content[0].text,/Review fixture/);
 const kb=await tool('search_knowledge',{query:'linux'});assert.match(kb.content[0].text,/kb\d{3}/);
 const info=await tool('inspect_task',{id:task});assert.match(info.content[0].text,/Observed fixture/);
 console.log('ZCode MCP graph, fact, knowledge and isolated task tests passed');
}finally{child.kill();server.close()}
