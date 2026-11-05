// SPDX-License-Identifier: MIT
/* tptest: can this process move its task/thread control port in a mach message? (argv[1]: self|special|thread|threadspecial) */
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv)
{
	const char *m = argc > 1 ? argv[1] : "special";
	mach_port_t rcv, port = MACH_PORT_NULL;
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rcv);
	mach_port_insert_right(mach_task_self(), rcv, rcv, MACH_MSG_TYPE_MAKE_SEND);
	kern_return_t kr = 0;
	if (!strcmp(m, "self")) port = mach_task_self();
	else if (!strcmp(m, "special")) kr = task_get_special_port(mach_task_self(), TASK_KERNEL_PORT, &port);
	else if (!strcmp(m, "thread")) port = mach_thread_self();
	else if (!strcmp(m, "threadspecial")) kr = thread_get_special_port(mach_thread_self(), THREAD_KERNEL_PORT, &port);
	printf("%s: kr=%d port=0x%x self=0x%x\n", m, kr, port, mach_task_self()); fflush(stdout);
	struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; } msg = {0};
	msg.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	msg.h.msgh_size = sizeof(msg); msg.h.msgh_remote_port = rcv;
	msg.b.msgh_descriptor_count = 1; msg.p.name = port; msg.p.disposition = MACH_MSG_TYPE_COPY_SEND; msg.p.type = MACH_MSG_PORT_DESCRIPTOR;
	kr = mach_msg_send(&msg.h);
	printf("send kr=0x%x\n", kr); fflush(stdout);
	struct { mach_msg_header_t h; mach_msg_body_t b; mach_msg_port_descriptor_t p; mach_msg_trailer_t t; } r = {0};
	kr = mach_msg(&r.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(r), rcv, 100, MACH_PORT_NULL);
	printf("recv kr=0x%x got port 0x%x\n", kr, r.p.name);
	if (!kr) {
		/* use it like wineserver would: read our own memory through the received right */
		vm_offset_t data; mach_msg_type_number_t cnt;
		static const char probe[] = "hello-task-port";
		kr = vm_read(r.p.name, (vm_address_t)probe, sizeof(probe), &data, &cnt);
		printf("vm_read via received port kr=0x%x %s\n", kr, kr ? "" : (char *)data);
	}
	printf("alive\n");
	return 0;
}
