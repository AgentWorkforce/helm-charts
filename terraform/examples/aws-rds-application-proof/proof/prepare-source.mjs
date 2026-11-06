/** Source-only preparation. No secret loader, DB connection, Docker or cloud. */
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {existsSync,lstatSync,mkdirSync,readFileSync,readdirSync,realpathSync,writeFileSync} from 'node:fs';
import {dirname,join,relative,resolve,sep} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';

const EXPECTED='292359f0c68b1e4615704fd51d303b7f6b4db445';
const BASE='5bd61f1261a4bb78a47f969a9cbc4bda7ac1d30c';
const OWNERS=[['623400709a030cbed39ffbe7a77d76b04ae26e54',11],['19101f78742cd4173dd55ee26aac2dfd49d6202c',23]];
const RUNTIME=['scripts/pg-proof/actual-rds-guest.ts','src/hoopdb/migrate.ts','src/hoopdb/migrate-guards.ts','src/hoopdb/migration-sentinels.ts','src/shared/db.ts','src/shared/log.ts','src/shared/env.ts','src/shared/locker-selection.ts','packages/pipeline/src/lib/scrub.ts'];
const here=dirname(fileURLToPath(import.meta.url));
const hash=b=>createHash('sha256').update(b).digest('hex');
const requireInvariant=(v,code)=>{if(!v)throw new Error(code);};
requireInvariant(process.versions.node.split('.')[0]==='24','source_node24_required');
requireInvariant(process.argv.length===4,'usage_source_root_and_NEW_output_directory');
const source=realpathSync(process.argv[2]),out=resolve(process.argv[3]);
if(process.platform==='darwin')requireInvariant(out.startsWith('/Volumes/T7/'),'output_requires_T7');
requireInvariant(!existsSync(out),'output_must_be_new');
const git=(...a)=>execFileSync('git',a,{cwd:source,encoding:'utf8',maxBuffer:16*1024*1024}).trim();
const clean=()=>{requireInvariant(git('rev-parse','HEAD')===EXPECTED,'unexpected_guest_commit');requireInvariant(!git('status','--porcelain','--untracked-files=normal'),'guest_tree_dirty');};
clean();
const ownerInputs={};
for(const [head,count] of OWNERS){
 const paths=git('diff','--name-only',BASE,head).split('\n');requireInvariant(paths.length===count,'owner_input_count_changed');
 for(const name of paths){const expected=execFileSync('git',['show',head+':'+name],{cwd:source,maxBuffer:16*1024*1024});requireInvariant(readFileSync(join(source,name)).equals(expected),'owner_input_changed');ownerInputs[name]=hash(expected);}
}
requireInvariant(Object.keys(ownerInputs).length===34,'expected_34_unchanged_owner_inputs');
mkdirSync(out,{recursive:true,mode:0o700});
// Preparation hook is outside the archive, and cannot affect the source checkout.
const prepHook=out+'.prepare-hook.mjs';
writeFileSync(prepHook,`import {install} from ${JSON.stringify(pathToFileURL(join(here,'register.mjs')).href)};install(new URL(${JSON.stringify(pathToFileURL(source+sep).href)}));\n`,{mode:0o600});
const capture=`const m=await import(${JSON.stringify(pathToFileURL(join(source,RUNTIME[0])).href)});console.log(JSON.stringify(await m.captureGuestSources()));`;
const manifest=JSON.parse(execFileSync(process.execPath,['--import',prepHook,'--input-type=module','-e',capture],{cwd:source,encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024}));
requireInvariant(manifest.compositionCommit===EXPECTED,'guest_manifest_commit_changed');
const files={};
function put(name,bytes){requireInvariant(!name.startsWith('/')&&!name.split('/').includes('..')&&!files[name],'unsafe_duplicate_archive_path');mkdirSync(dirname(join(out,name)),{recursive:true});writeFileSync(join(out,name),bytes,{mode:0o600});files[name]=hash(bytes);}
for(const name of new Set([...Object.keys(manifest.files),...RUNTIME,'tsconfig.json'])){
 requireInvariant(name!=='scripts/pg-proof/rds-profile-proof.ts','emulation_must_not_ship');
 const path=join(source,name);requireInvariant(lstatSync(path).isFile()&&!lstatSync(path).isSymbolicLink(),'source_not_regular');put('source/'+name,readFileSync(path));
}
put('guest-sources.json',Buffer.from(JSON.stringify(manifest)+'\n'));
for(const name of ['register.mjs','runtime-hook.mjs','import-check.mjs'])put(name,readFileSync(join(here,name)));
// Bun's lock stores package records on individual JSON lines. Parse only those
// exact records with JSON.parse; never evaluate text or invent an npm lock.
const lock=readFileSync(join(source,'bun.lock'),'utf8');const records=[];
for(const line of lock.split('\n'))if(/^\s*"[^"\n]+": \[/.test(line)){
 const pair=JSON.parse('{'+line.trim().replace(/,$/,'')+'}');records.push(Object.values(pair)[0]);
}
const packages={};
function packageRoot(request,name){
 let entry;try{entry=request.resolve(name+'/package.json');}catch{entry=request.resolve(name);}
 let folder=dirname(entry);
 while(folder!==dirname(folder)){
  const file=join(folder,'package.json');if(existsSync(file)&&JSON.parse(readFileSync(file)).name===name)return realpathSync(folder);
  folder=dirname(folder);
 }
 throw new Error('dependency_package_missing');
}
function dependency(request,name){
 const folder=packageRoot(request,name);requireInvariant(folder.startsWith(source+sep+'node_modules'+sep),'dependency_outside_own_install');
 const pkg=JSON.parse(readFileSync(join(folder,'package.json')));requireInvariant(pkg.name===name&&typeof pkg.version==='string','invalid_dependency_identity');
 const record=records.filter(r=>r[0]===name+'@'+pkg.version);requireInvariant(record.length===1&&/^sha512-/.test(record[0][3]),'dependency_not_exactly_in_bun_lock');
 if(packages[name]){requireInvariant(packages[name].version===pkg.version,'flat_dependency_version_conflict');return;}
 packages[name]={version:pkg.version,lock_integrity:record[0][3]};
 const local=createRequire(join(folder,'package.json'));
 for(const dep of Object.keys(pkg.dependencies||{}))dependency(local,dep);
 for(const dep of Object.keys(pkg.optionalDependencies||{})){
  try{local.resolve(dep);}catch{continue;}dependency(local,dep);
 }
 function walk(path,prefix=''){
  for(const leaf of readdirSync(path).sort()){
   if(leaf==='node_modules')continue;
   const abs=join(path,leaf),rel=prefix+leaf,st=lstatSync(abs);requireInvariant(!st.isSymbolicLink(),'package_symlink_refused');
   if(st.isDirectory())walk(abs,rel+'/');else {requireInvariant(st.isFile(),'package_special_file_refused');put('node_modules/'+name+'/'+rel,readFileSync(abs));}
  }
 }
 walk(folder);
}
dependency(createRequire(join(source,'package.json')),'pg');
requireInvariant(packages.pg.version==='8.23.1','pg_version_changed');
clean();
const outer={format:'actual-rds-source-archive-v1',composition_commit:EXPECTED,composition_tree:git('rev-parse','HEAD^{tree}'),bun_lock_sha256:hash(Buffer.from(lock)),owner_input_sha256:ownerInputs,packages,files};
writeFileSync(join(out,'archive-manifest.json'),JSON.stringify(outer,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({ok:true,scope:'source preparation only; installed execution still required',output:out,source_commit:EXPECTED,owner_inputs:34,pg:packages.pg.version,packages:Object.keys(packages).length,files:Object.keys(files).length,manifest_sha256:hash(readFileSync(join(out,'archive-manifest.json')))}));
