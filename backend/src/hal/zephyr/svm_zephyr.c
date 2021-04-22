/**********************************************************************************/
/* MIT License									  */
/* 										  */
/* Copyright (c) 2021 Joel Svensson, Abhiroop Sarkar             		  */
/* 										  */
/* Permission is hereby granted, free of charge, to any person obtaining a copy	  */
/* of this software and associated documentation files (the "Software"), to deal  */
/* in the Software without restriction, including without limitation the rights	  */
/* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell	  */
/* copies of the Software, and to permit persons to whom the Software is	  */
/* furnished to do so, subject to the following conditions:			  */
/* 										  */
/* The above copyright notice and this permission notice shall be included in all */
/* copies or substantial portions of the Software.				  */
/* 										  */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR	  */
/* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,	  */
/* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE	  */
/* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER	  */
/* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,  */
/* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE  */
/* SOFTWARE.									  */
/**********************************************************************************/

/*******************/
/* Zephyr includes */
#include <zephyr/types.h>
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#include <zephyr.h>
#include <sys/printk.h>
#include <sys/byteorder.h>
#include <sys/ring_buffer.h>

/********************/
/* SenseVM Includes */

#include <vm-conf.h>
#include <VMC.h>

/***************************************************/
/* Check for configurations that are not sensible. */
/* Compile time error stuff...                     */

#if VMC_NUM_CONTAINERS > 4
#error "Too many containers specified in vm-conf.h"
#endif

/*********************************************/
/* Declare stacks and threads for containers */

#define STACK_SIZE 512

struct k_thread vmc_zephyr_thread[4];
k_thread_stack_t vmc_zephyr_stack[4];
struct k_mbox zephyr_thread_mbox[4];

vmc_t vm_containers[4]; /* SenseVM containers */


#if VMC_NUM_CONTAINERS >= 1
K_THREAD_STACK_DEFINE(vmc_zephyr_stack_0, STACK_SIZE);
vmc_zephyr_stack[0] = vmc_zephyr_stack_0;
#endif
#if VMC_NUM_CONTAINERS >= 2
K_THREAD_STACK_DEFINE(vmc_zephyr_stack_1, STACK_SIZE);
vmc_zephyr_stack[0] = vmc_zephyr_stack_1;
#endif
#if VMC_NUM_CONTAINERS >= 3
K_THREAD_STACK_DEFINE(vmc_zephyr_stack_2, STACK_SIZE);
vmc_zephyr_stack[0] = vmc_zephyr_stack_2;
#endif
#if VMC_NUM_CONTAINERS >= 4
K_THREAD_STACK_DEFINE(vmc_zephyr_stack_3, STACK_SIZE);
vmc_zephyr_stack[0] = vmc_zephyr_stack_3;
#endif


/***********************************************/
/* Zephyr thread for containing a VM container */

void zephyr_container_thread(void* vmc, void* b, void* c) {
  (void)b;
  (void)c;  /* These are unused so far. otherwise a way to pass arguments to the thread */ 

  vmc_t *container = vmc;


  struct k_mbox_msg recv_msg;


  while (1) {

    /* Do stuff */
    /* Like run the scheduler */



    /* This is a blocking call that waits until
       there is something in the messagebox.
       Maybe here it is better to have a non-blocking
       peek at the mbox and then do something else (if
       there is something else to do). If there is nothing
       else to do, we could then call the blocking
       mbox_get. */
    k_mbox_get(&tick_mbox, &recv_msg, NULL, K_FOREVER);

    /* use the messages from the mbox to add tasts to the
       queue for the next launch of the scheduler */

    /* There should be an interface in VMC.h for
       creating this datastructure to pass data
       back and forth from the zephyr thread and the
       scheduler in the container */


  }
}

void zephyr_start_container_threads(void) {

  for (int i = 0; i < VMC_NUM_CONTAINERS; i ++) {

    /* We can set different priorities on
       different containers */

    k_thread_create(&vmc_zephyr_thread[i], vmc_zephyr_stack[i],
		    K_THREAD_STACK_SIZEOF(vmc_zephyr_stack[i]),
		    zephyr_container_thread,
		    (void*)&(vm_containers[i]), NULL, NULL,
		    5, 0, K_NO_WAIT);
  }
}

void zephyr_sensevm_init(void) {

  /* Initialize all message boxes */

  for (int i = 0; i < VMC_NUM_CONTAINERS; i ++) {
    k_mbox_init(&zephyr_thread_mbox[i]);
  }

}
