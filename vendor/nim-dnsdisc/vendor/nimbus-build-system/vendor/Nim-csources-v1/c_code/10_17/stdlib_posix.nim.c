/* Generated by Nim Compiler v1.0.11 */
/*   (c) 2019 Andreas Rumpf */
/* The generated code is subject to the original license. */
#define NIM_INTBITS 64

#include "nimbase.h"
#include <sys/types.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <signal.h>
#include <time.h>
#undef LANGUAGE_C
#undef MIPSEB
#undef MIPSEL
#undef PPC
#undef R3000
#undef R4000
#undef i386
#undef linux
#undef mips
#undef near
#undef far
#undef powerpc
#undef unix
#define nimfr_(x, y)
#define nimln_(x, y)
typedef struct TNimType TNimType;
typedef struct TNimNode TNimNode;
typedef NU8 tyEnum_TNimKind__jIBKr1ejBgsfM33Kxw4j7A;
typedef NU8 tySet_tyEnum_TNimTypeFlag__v8QUszD1sWlSIWZz7mC4bQ;
typedef N_NIMCALL_PTR(void, tyProc__ojoeKfW4VYIm36I9cpDTQIg) (void* p, NI op);
typedef N_NIMCALL_PTR(void*, tyProc__WSm2xU5ARYv9aAR4l0z9c9auQ) (void* p);
struct TNimType {
NI size;
tyEnum_TNimKind__jIBKr1ejBgsfM33Kxw4j7A kind;
tySet_tyEnum_TNimTypeFlag__v8QUszD1sWlSIWZz7mC4bQ flags;
TNimType* base;
TNimNode* node;
void* finalizer;
tyProc__ojoeKfW4VYIm36I9cpDTQIg marker;
tyProc__WSm2xU5ARYv9aAR4l0z9c9auQ deepcopy;
};
TNimType NTI__r9bTMVI8f19ah9b11jMgY4kPg_;
N_LIB_PRIVATE N_NIMCALL(int, sigtimedwait__rfmeg1U9coJfbpyxllm3vWQ)(sigset_t* a1, siginfo_t* a2, struct timespec* a3) {	int result;
	long T1_;
	result = (int)0;
	T1_ = (long)0;
	T1_ = syscall(__NR_rt_sigtimedwait, a1, a2, a3, (NI)(NSIG / ((NI) 8)));
	result = ((int) (T1_));
	return result;
}
N_LIB_PRIVATE N_NIMCALL(void, stdlib_posixDatInit000)(void) {
NTI__r9bTMVI8f19ah9b11jMgY4kPg_.size = sizeof(pid_t);
NTI__r9bTMVI8f19ah9b11jMgY4kPg_.kind = 34;
NTI__r9bTMVI8f19ah9b11jMgY4kPg_.base = 0;
NTI__r9bTMVI8f19ah9b11jMgY4kPg_.flags = 3;
}
