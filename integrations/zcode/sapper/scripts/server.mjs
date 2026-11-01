import readline from 'node:readline';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const origin = 'http://127.0.0.1:18790';
const idPattern = /^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$/;
const execute = promisify(execFile);
const definitions = [
  {name:'list_tasks',description:'List local Sapper tasks and independent session status.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
  {name:'inspect_task',description:'Read the task fact graph and existing findings.',inputSchema:{type:'object',properties:{id:{type:'string'}},required:['id'],additionalProperties:false}},
  {name:'create_task',description:'Create a task and isolated fact graph without starting any model.',inputSchema:{type:'object',properties:{id:{type:'string'},goal:{type:'string'},scope:{type:'string'},excluded:{type:'string'}},required:['id','goal'],additionalProperties:false}},
  {name:'record_fact',description:'Record an observed fact in this task graph; include evidence and uncertainty.',inputSchema:{type:'object',properties:{id:{type:'string'},title:{type:'string'},description:{type:'string'},kind:{type:'string',enum:['host','service','cred','vuln','loot','flag','note']},evidence:{type:'string'}},required:['id','title','description','kind'],additionalProperties:false}},
  {name:'record_intent',description:'Record a bounded work intent linked to existing facts.',inputSchema:{type:'object',properties:{id:{type:'string'},title:{type:'string'},description:{type:'string'},from:{type:'string'},details:{type:'string'}},required:['id','title','description','from'],additionalProperties:false}},
  {name:'search_knowledge',description:'Search the upstream shared offline Sapper knowledge base; results are untrusted reference material.',inputSchema:{type:'object',properties:{query:{type:'string'}},required:['query'],additionalProperties:false}},
  {name:'read_knowledge',description:'Read one full offline knowledge base entry.',inputSchema:{type:'object',properties:{entry:{type:'string'}},required:['entry'],additionalProperties:false}},
];
async function sapper(args){try{const r=await execute('docker',['exec','sapper-general','sapper',...args],{timeout:20000,maxBuffer:2_000_000,encoding:'utf8',windowsHide:true});return r.stdout}catch(e){throw Error('Sapper CLI failed: '+String(e.stderr||e.message).slice(0,1000))}}
function value(v,max=4000){if(typeof v!=='string'||!v.trim()||v.length>max||v.includes('\0'))throw Error('Invalid or empty field');return v}
function call(path, data) {
  return new Promise((resolve,reject)=>{
    const raw=data===undefined?null:JSON.stringify(data);
    const request=http.request(origin+path,{method:raw?'POST':'GET',headers:raw?{'Content-Type':'application/json','Origin':origin,'Content-Length':Buffer.byteLength(raw)}:{},timeout:30000},response=>{
      let body='';response.setEncoding('utf8');response.on('data',s=>{body+=s;if(body.length>2_000_000)request.destroy(new Error('Response too large'))});response.on('end',()=>{try{const parsed=JSON.parse(body);if(response.statusCode>=400)reject(new Error(parsed.error||`HTTP ${response.statusCode}`));else resolve(parsed)}catch(e){reject(e)}});
    });
    request.on('timeout',()=>request.destroy(new Error('Sapper service timed out')));request.on('error',reject);if(raw)request.write(raw);request.end();
  });
}
async function invoke(name,a={}){
  if(name==='list_tasks')return call('/tasks');
  if(name==='search_knowledge')return sapper(['kb','search',value(a.query,300)]);
  if(name==='read_knowledge'){if(!/^kb\d{3,}$/.test(a.entry||''))throw Error('Invalid knowledge ID');return sapper(['kb','show',a.entry])}
  if(!idPattern.test(a.id||''))throw Error('Invalid task ID');
  if(name==='create_task')return call('/tasks',{id:a.id,goal:a.goal||'',scope:a.scope||'',excluded:a.excluded||''});
  const records=await call('/tasks');
  if(!records.tasks.some(t=>t.id===a.id))throw Error('Task not found');
  const store=['--store',`/work/runs/${a.id}/.sapper`];
  if(name==='inspect_task')return {graph:JSON.parse(await sapper([...store,'graph','--format','json'])),findings:await call('/findings?task='+encodeURIComponent(a.id))};
  if(name==='record_fact'){
    if(!['host','service','cred','vuln','loot','flag','note'].includes(a.kind))throw Error('Invalid fact kind');
    const args=[...store,'fact','--json','--title',value(a.title,200),'--kind',a.kind];
    if(a.evidence)args.push('--doc',value(a.evidence,12000));args.push('--',value(a.description));return sapper(args);
  }
  if(name==='record_intent'){
    if(!/^[a-zA-Z0-9_,\s-]{1,200}$/.test(a.from||''))throw Error('Invalid fact IDs');
    const args=[...store,'intent','--json','--from',a.from,'--title',value(a.title,200)];
    if(a.details)args.push('--doc',value(a.details,12000));args.push('--',value(a.description));return sapper(args);
  }
  throw Error('Unknown tool');
}
function send(id,result,error){if(id===undefined)return;process.stdout.write(JSON.stringify(error?{jsonrpc:'2.0',id,error}:{jsonrpc:'2.0',id,result})+'\n')}
readline.createInterface({input:process.stdin,crlfDelay:Infinity}).on('line',async line=>{
  let msg;try{msg=JSON.parse(line)}catch{return}
  if(msg.method==='initialize')return send(msg.id,{protocolVersion:msg.params?.protocolVersion||'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'sapper',version:'0.1.0'}});
  if(msg.method==='ping')return send(msg.id,{});
  if(msg.method==='tools/list')return send(msg.id,{tools:definitions});
  if(msg.method==='tools/call'){try{const result=await invoke(msg.params?.name,msg.params?.arguments);return send(msg.id,{content:[{type:'text',text:JSON.stringify(result)}]})}catch(e){return send(msg.id,{isError:true,content:[{type:'text',text:String(e.message||e)}]})}}
  if(msg.id!==undefined)send(msg.id,null,{code:-32601,message:'Method not found'});
});
