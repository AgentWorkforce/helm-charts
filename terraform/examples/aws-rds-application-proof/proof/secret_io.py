"""Bounded memory-only child IO. Never logs arguments, input, output or foreign errors.

This is transport, not approval authority or an isolation boundary. Callers must
provide trusted argument arrays, exact operation scope and a durable pending
record before mutation. No disk logger or credential discovery is used here.
"""
import os
import selectors
import signal
import subprocess
import time

class SecretIoError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)

class Result:
    def __init__(self, returncode, stdout, stderr):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
    def __repr__(self): return '<SensitiveResult: contents omitted>'

def run(args, *, input_bytes=b'', env, timeout=90, max_output=65536, max_input=131072):
    if not isinstance(input_bytes, bytes) or len(input_bytes)>max_input or not 0<max_input<=8*1024*1024 or not 0<timeout<=300 or not 0<max_output<=1048576:
        raise SecretIoError('sensitive_input_bound')
    process=None;selector=selectors.DefaultSelector();buffers={'stdout':bytearray(),'stderr':bytearray()};offset=0
    def settle():
        if process is None:return True
        for sig in [signal.SIGTERM,signal.SIGKILL]:
            process.poll()
            try:os.killpg(process.pid,sig)
            except ProcessLookupError:return True
            end=time.monotonic()+5
            while time.monotonic()<end:
                process.poll()
                try:os.killpg(process.pid,0)
                except ProcessLookupError:return True
                time.sleep(.05)
        return False
    try:
        process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
        for name,stream in [('stdout',process.stdout),('stderr',process.stderr)]:
            os.set_blocking(stream.fileno(),False);selector.register(stream,selectors.EVENT_READ,name)
        os.set_blocking(process.stdin.fileno(),False)
        if input_bytes:selector.register(process.stdin,selectors.EVENT_WRITE,'stdin')
        else:process.stdin.close()
        deadline=time.monotonic()+timeout
        while selector.get_map():
            remaining=deadline-time.monotonic()
            if remaining<=0:raise SecretIoError('sensitive_timeout')
            for key,_ in selector.select(min(.1,remaining)):
                if key.data=='stdin':
                    try:offset+=os.write(key.fd,input_bytes[offset:offset+4096])
                    except BrokenPipeError:offset=len(input_bytes)
                    if offset==len(input_bytes):selector.unregister(key.fileobj);key.fileobj.close()
                else:
                    chunk=os.read(key.fd,4096)
                    if not chunk:selector.unregister(key.fileobj);key.fileobj.close();continue
                    if len(buffers[key.data])+len(chunk)>max_output:raise SecretIoError('sensitive_output_bound')
                    buffers[key.data].extend(chunk)
        remaining=deadline-time.monotonic()
        if remaining<=0:raise SecretIoError('sensitive_timeout')
        try:process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:raise SecretIoError('sensitive_timeout') from None
        if not settle():raise SecretIoError('sensitive_process_unsettled')
        return Result(process.returncode,bytes(buffers['stdout']),bytes(buffers['stderr']))
    except BaseException as error:
        settled=settle()
        if isinstance(error,(KeyboardInterrupt,SystemExit)):raise
        if not settled:raise SecretIoError('sensitive_process_unsettled') from None
        if isinstance(error,SecretIoError):raise
        raise SecretIoError('sensitive_process_failed') from None
    finally:
        selector.close()
        if process is not None:
            for stream in [process.stdin,process.stdout,process.stderr]:
                if not stream.closed:stream.close()
