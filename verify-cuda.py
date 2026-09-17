#!/usr/bin/env python3
"""Small CUDA Driver API compute check on every visible GPU; no toolkit required."""
import ctypes as c
import json

cuda=c.CDLL('libcuda.so.1')
def call(name, *args):
    code=getattr(cuda,name)(*args)
    if code:
        error=c.c_char_p()
        cuda.cuGetErrorString(code,c.byref(error))
        raise RuntimeError(f'{name}: {code}: {error.value.decode() if error.value else "unknown"}')

ptx=b'''.version 8.0
.target sm_75
.address_size 64
.visible .entry double_values(.param .u64 output) {
.reg .b32 r<3>;
.reg .b64 rd<3>;
ld.param.u64 rd1, [output];
mov.u32 r1, %tid.x;
mul.wide.u32 rd2, r1, 4;
add.u64 rd2, rd1, rd2;
shl.b32 r2, r1, 1;
st.global.u32 [rd2], r2;
ret;
}
'''
call('cuInit',0)
count=c.c_int()
call('cuDeviceGetCount',c.byref(count))
assert count.value>0,'No CUDA devices'
results=[]
for index in range(count.value):
    device=c.c_int(); context=c.c_void_p(); module=c.c_void_p(); memory=c.c_uint64(); fn=c.c_void_p()
    call('cuDeviceGet',c.byref(device),index)
    name=c.create_string_buffer(128)
    call('cuDeviceGetName',name,128,device)
    call('cuCtxCreate_v2',c.byref(context),0,device)
    try:
        call('cuModuleLoadData',c.byref(module),c.c_char_p(ptx))
        call('cuModuleGetFunction',c.byref(fn),module,c.c_char_p(b'double_values'))
        call('cuMemAlloc_v2',c.byref(memory),c.c_size_t(256*4))
        params=(c.c_void_p*1)(c.cast(c.byref(memory),c.c_void_p))
        call('cuLaunchKernel',fn,1,1,1,256,1,1,0,c.c_void_p(),params,c.c_void_p())
        call('cuCtxSynchronize')
        output=(c.c_uint32*256)()
        call('cuMemcpyDtoH_v2',output,memory,c.c_size_t(c.sizeof(output)))
        assert list(output)==[x*2 for x in range(256)],f'GPU {index}: incorrect compute result'
        results.append({'gpu':index,'name':name.value.decode(),'cuda_compute':'passed','values_checked':256})
    finally:
        if memory.value: call('cuMemFree_v2',memory)
        if module.value: call('cuModuleUnload',module)
        call('cuCtxDestroy_v2',context)
print(json.dumps({'devices':results,'all_passed':True},indent=2))
