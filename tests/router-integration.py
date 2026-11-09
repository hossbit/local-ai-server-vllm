"""Local-only HTTP integration: real llama-swap, synthetic inference servers."""
import hashlib, json, os, signal, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve()
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
args=sys.argv
port=int(args[args.index('--port')+1]); model=args[args.index('--served-model-name')+1]
backend='omni' if '--omni' in args else 'vllm'
with open(os.environ['FAKE_PID_LOG'],'a') as f: f.write(str(os.getpid())+'\n')
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path=='/':
   self.send_response(404); self.end_headers(); return
  body=json.dumps({'data':[{'id':model}]}).encode() if self.path=='/v1/models' else b'OK'
  if self.path=='/metrics': body=b'vllm:num_requests_running 1\nvllm:num_requests_waiting 0\nvllm:generation_tokens_total 10\n'
  self.send_response(200); self.end_headers(); self.wfile.write(body)
 def do_POST(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
  payload=json.loads(raw) if 'json' in self.headers.get('Content-Type','') else {}
  info={'model':model,'backend':backend,'pid':os.getpid(),'content_type':self.headers.get('Content-Type','')}
  self.send_response(200)
  if self.path=='/v1/audio/speech':
   self.send_header('Content-Type','audio/wav'); body=b'MOCK_AUDIO'
  elif payload.get('stream'):
   self.send_header('Content-Type','text/event-stream'); body=('data: '+json.dumps(info)+'\n\ndata: [DONE]\n\n').encode()
  else:
   self.send_header('Content-Type','application/json'); body=json.dumps(info).encode()
  self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
print('TEST_WORKER_LOG '+backend+' '+model,flush=True)
ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
'''

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]

def alive(pid):
    try: os.kill(pid,0); return True
    except ProcessLookupError: return False

def request(base,path,body=None,key=None,ctype='application/json'):
    headers={'Content-Type':ctype}
    if key: headers['Authorization']='Bearer '+key
    if isinstance(body,dict): body=json.dumps(body).encode()
    req=urllib.request.Request(base+path,data=body,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=15) as r: return r.status,r.read()
    except urllib.error.HTTPError as e: return e.code,e.read()

def model_states(env, backend):
    # The synthetic worker is started directly, rather than through systemd.
    script = r'''
    set -euo pipefail
    SCRIPT_DIR="$1"
    . "$SCRIPT_DIR/localvllm.conf"
    . "$SCRIPT_DIR/lib/common.sh"
    AI_DIR="$LOCALVLLM_DIR"; CONF_ROOT="$AI_DIR/conf"
    . "$SCRIPT_DIR/lib/cli/core.sh"
    . "$SCRIPT_DIR/lib/cli/service.sh"
    . "$SCRIPT_DIR/lib/cli/models.sh"
    localvllm_capture_global_runtime
    localvllm_use_backend "$2"
    service_is_active() { return 0; }
    models_cmd --json
    '''
    return json.loads(subprocess.check_output(['bash','-c',script,'test',str(REPO),backend], env=env))

def wait_ready(base):
    for _ in range(100):
        try:
            if request(base,'/health')[0]==200: return
        except OSError: pass
        time.sleep(.05)
    raise AssertionError('server did not start')

def stop(proc):
    if proc.poll() is None:
        os.killpg(proc.pid,signal.SIGTERM)
        try: proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL); proc.wait()

with tempfile.TemporaryDirectory(prefix='localvllm integration ') as temp:
    ai=Path(temp)/'ai'; log=Path(temp)/'pids'; log.touch()
    env=os.environ.copy(); env.update(LOCALVLLM_DIR=str(ai),LOCALVLLM_LLAMA_SWAP_BIN=str(BINARY),FAKE_PID_LOG=str(log))
    secret='sk-localvllm-'+'a'*64
    for backend in ('vllm','omni'):
        state=ai/'conf/backends'/backend; (state/'models.d').mkdir(parents=True)
        bins=ai/'venv'/backend/'bin'; bins.mkdir(parents=True)
        (bins/'vllm').write_text(FAKE); (bins/'vllm').chmod(0o755)
        (bins/'python').write_text('#!/bin/sh\nexit 0\n'); (bins/'python').chmod(0o755)
        for model in ('model-a','model-b'):
            folder=ai/'models'/backend/model; folder.mkdir(parents=True); (folder/'config.json').write_text('{}')
        (state/'active-model').write_text('model-a\n')
        keyid=hashlib.sha256(secret.encode()).hexdigest()[:12]
        (state/'api-keys.tsv').write_text(f'version\t1\n{keyid}\ttest\t2026-01-01T00:00:00Z\tactive\t{secret}\n')
        for mode in ('swap','direct'):
            port=free_port(); base=f'http://127.0.0.1:{port}'
            (state/'port').write_text(str(port)); (state/'serving-mode').write_text(mode)
            subprocess.run(['bash',str(REPO/'rebuild-config.sh'),'--backend',backend],env=env,check=True,stdout=subprocess.DEVNULL)
            if mode=='swap':
                configs=list((state/'router').glob('*.json')); config=max(configs,key=lambda p:p.stat().st_mtime_ns)
                data=json.loads(config.read_text()); data['startPort']=free_port(); config.write_text(json.dumps(data)); config.chmod(0o600)
                subprocess.run([str(BINARY),'-config',str(config),'-validate'],check=True,stdout=subprocess.DEVNULL)
            with open(Path(temp)/f'{backend}-{mode}.log','wb') as output:
                proc=subprocess.Popen(['bash',str(state/'serve.sh')],env=env,stdout=output,stderr=output,start_new_session=True)
                try:
                    wait_ready(base)
                    if mode=='swap':
                        assert request(base,'/ui',key=secret)[0]==200
                        assert request(base,'/v1/chat/completions',{'model':'model-a'})[0] in (401,403)
                        inventory=json.loads(request(base,'/v1/models',key=secret)[1]); assert len(inventory['data'])==2
                        assert request(base,'/upstream/model-a/health',key=secret)[0]==200
                    code,raw=request(base,'/v1/chat/completions',{'model':'model-a'},secret)
                    assert code==200,raw
                    first=json.loads(raw); assert first['backend']==backend
                    metrics=subprocess.check_output(['bash',str(REPO/'localvllm'),'--backend',backend,'metrics'],env=env,text=True)
                    assert 'Running requests: 1' in metrics,metrics
                    runtime_log=(Path(temp)/f'{backend}-{mode}.log').read_text()
                    assert f'TEST_WORKER_LOG {backend} model-a' in runtime_log,runtime_log

                    if mode=='swap':
                        second=json.loads(request(base,'/v1/chat/completions',{'model':'model-b'},secret)[1])
                        assert second['model']=='model-b' and second['pid']!=first['pid']
                        assert not alive(first['pid']), 'previous worker survived model swap'
                        live=model_states(env,backend)
                        assert live['active_model']=='model-b' and live['direct_model']=='model-a',live
                        assert live['active_models']==['model-b'] and live['runtime_state_available'],live
                        states={m['id']:m['state'] for m in live['models']}
                        assert states=={'model-a':'unloaded','model-b':'loaded'},states
                        for endpoint in ('/v1/embeddings','/v1/images/generations','/v1/responses'):
                            assert request(base,endpoint,{'model':'model-b'},secret)[0]==200
                        assert request(base,'/v1/audio/speech',{'model':'model-b'},secret)[1]==b'MOCK_AUDIO'
                        multipart=b'--test\r\nContent-Disposition: form-data; name="model"\r\n\r\nmodel-b\r\n--test\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\naudio\r\n--test--\r\n'
                        code,raw=request(base,'/v1/audio/transcriptions',multipart,secret,'multipart/form-data; boundary=test')
                        assert code==200,raw
                        assert json.loads(raw)['backend']==backend
                        code,raw=request(base,'/v1/chat/completions',{'model':'model-b','stream':True},secret)
                        assert code==200 and b'[DONE]' in raw
                        assert request(base,'/api/models/unload',b'',secret)[0]==200
                        assert not alive(second['pid']), 'worker survived unload'
                        before=log.read_text()
                        idle=subprocess.check_output(['bash',str(REPO/'localvllm'),'--backend',backend,'metrics'],env=env,text=True)
                        assert 'No ready model' in idle,idle
                        assert log.read_text()==before,'metrics unexpectedly started a worker'

                        live=model_states(env,backend)
                        assert live['active_models']==[] and all(m['state']=='unloaded' for m in live['models']),live
                    print(f'PASS {backend} {mode}: routing/auth/streaming/endpoints/lifecycle' if mode=='swap' else f'PASS {backend} direct: native launcher and API')
                finally: stop(proc)
    for pid in map(int,log.read_text().splitlines()):
        assert not alive(pid),f'worker {pid} leaked after shutdown'
    print('PASS no orphan workers')
